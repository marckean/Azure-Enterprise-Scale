#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

<#
.SYNOPSIS
    Creates a comprehensive inventory of virtual networks and their workloads across all subscriptions in Azure tenant.

.DESCRIPTION
    This script traverses all subscriptions in the current Azure tenant and creates an inventory of:
    - Virtual networks in Australia East region
    - All resources within each virtual network (VMs, storage, databases, etc.)
    - Detailed information for planning migration from traditional hub to Azure Virtual WAN Hub
    
    The output includes subscription details, resource group information, and workload categorization
    to help identify production vs non-production workloads.

.PARAMETER OutputPath
    Path where the CSV files will be saved. Defaults to current directory.

.PARAMETER Region
    Azure region to focus on. Defaults to "Australia East".

.EXAMPLE
    .\Get-VNetInventory.ps1 -OutputPath "C:\temp\azure-inventory"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory = $false)]
    [string]$Region = "Australia East"
)

# Initialize results arrays
$vnetInventory = @()
$vmInventory = @()
$resourceInventory = @()
$networkDetails = @()

# Function to determine if workload is likely production based on naming conventions
function Get-WorkloadType {
    param(
        [string]$Name,
        [string]$ResourceGroupName,
        [string]$SubscriptionName
    )
    
    $prodIndicators = @('prod', 'production', 'live', 'prd')
    $nonProdIndicators = @('dev', 'development', 'test', 'staging', 'uat', 'sit', 'nonprod', 'non-prod', 'sandbox', 'poc', 'demo')
    
    $allText = "$Name $ResourceGroupName $SubscriptionName".ToLower()
    
    foreach ($indicator in $prodIndicators) {
        if ($allText -contains $indicator) {
            return "Production"
        }
    }
    
    foreach ($indicator in $nonProdIndicators) {
        if ($allText -contains $indicator) {
            return "Non-Production"
        }
    }
    
    return "Unknown"
}

# Function to get VM details including size, OS, and network configuration
function Get-VMDetails {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$VMName
    )
    
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
        if ($vm) {
            $vmSize = $vm.HardwareProfile.VmSize
            $osType = if ($vm.StorageProfile.OsDisk.OsType) { $vm.StorageProfile.OsDisk.OsType } else { "Unknown" }
            
            # Get network interfaces
            $nics = @()
            foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
                $nicId = $nicRef.Id
                $nic = Get-AzNetworkInterface | Where-Object { $_.Id -eq $nicId }
                if ($nic) {
                    foreach ($ipConfig in $nic.IpConfigurations) {
                        $nics += @{
                            NicName = $nic.Name
                            PrivateIP = $ipConfig.PrivateIpAddress
                            SubnetId = $ipConfig.Subnet.Id
                            PublicIP = if ($ipConfig.PublicIpAddress) { "Yes" } else { "No" }
                        }
                    }
                }
            }
            
            return @{
                VMSize = $vmSize
                OSType = $osType
                NetworkInterfaces = $nics
            }
        }
    }
    catch {
        Write-Warning "Could not get details for VM $VMName in RG $ResourceGroupName"
    }
    
    return $null
}

# Check if user is logged in
Write-Host "Checking Azure authentication..." -ForegroundColor Green
$context = Get-AzContext
if (-not $context) {
    Write-Host "Please login to Azure first using Connect-AzAccount" -ForegroundColor Red
    exit 1
}

Write-Host "Logged in as: $($context.Account.Id)" -ForegroundColor Green
Write-Host "Current tenant: $($context.Tenant.Id)" -ForegroundColor Green

# Get all subscriptions
Write-Host "`nGetting all subscriptions..." -ForegroundColor Green
$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
Write-Host "Found $($subscriptions.Count) enabled subscriptions" -ForegroundColor Green

$totalSubscriptions = $subscriptions.Count
$currentSubscription = 0

foreach ($subscription in $subscriptions) {
    $currentSubscription++
    Write-Host "`n[$currentSubscription/$totalSubscriptions] Processing subscription: $($subscription.Name)" -ForegroundColor Yellow
    
    try {
        # Set subscription context
        Set-AzContext -SubscriptionId $subscription.Id | Out-Null
        
        # Get all virtual networks in the specified region
        $vnets = Get-AzVirtualNetwork | Where-Object { $_.Location -eq $Region }
        
        if ($vnets.Count -eq 0) {
            Write-Host "  No virtual networks found in $Region" -ForegroundColor Gray
            continue
        }
        
        Write-Host "  Found $($vnets.Count) virtual networks in $Region" -ForegroundColor Cyan
        
        foreach ($vnet in $vnets) {
            Write-Host "    Processing VNet: $($vnet.Name)" -ForegroundColor White
            
            # Get subnets
            $subnets = $vnet.Subnets
            $subnetInfo = @()
            
            foreach ($subnet in $subnets) {
                $subnetInfo += @{
                    Name = $subnet.Name
                    AddressPrefix = $subnet.AddressPrefix -join ", "
                    ConnectedDevices = $subnet.IpConfigurations.Count
                }
            }
            
            # Determine workload type
            $workloadType = Get-WorkloadType -Name $vnet.Name -ResourceGroupName $vnet.ResourceGroupName -SubscriptionName $subscription.Name
            
            # Add to VNet inventory
            $vnetRecord = [PSCustomObject]@{
                SubscriptionId = $subscription.Id
                SubscriptionName = $subscription.Name
                ResourceGroupName = $vnet.ResourceGroupName
                VNetName = $vnet.Name
                VNetId = $vnet.Id
                Location = $vnet.Location
                AddressSpace = $vnet.AddressSpace.AddressPrefixes -join ", "
                SubnetCount = $subnets.Count
                SubnetDetails = ($subnetInfo | ForEach-Object { "$($_.Name) ($($_.AddressPrefix))" }) -join "; "
                WorkloadType = $workloadType
                DnsServers = $vnet.DhcpOptions.DnsServers -join ", "
                Tags = ($vnet.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; "
            }
            $vnetInventory += $vnetRecord
            
            # Get all resources in the same resource group as the VNet
            $resources = Get-AzResource -ResourceGroupName $vnet.ResourceGroupName
            
            # Filter resources that are likely in this VNet (network-related resources)
            foreach ($resource in $resources) {
                $resourceWorkloadType = Get-WorkloadType -Name $resource.Name -ResourceGroupName $resource.ResourceGroupName -SubscriptionName $subscription.Name
                
                $resourceRecord = [PSCustomObject]@{
                    SubscriptionId = $subscription.Id
                    SubscriptionName = $subscription.Name
                    ResourceGroupName = $resource.ResourceGroupName
                    VNetName = $vnet.Name
                    ResourceName = $resource.Name
                    ResourceType = $resource.ResourceType
                    Location = $resource.Location
                    WorkloadType = $resourceWorkloadType
                    Tags = ($resource.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; "
                }
                $resourceInventory += $resourceRecord
                
                # If it's a VM, get detailed information
                if ($resource.ResourceType -eq "Microsoft.Compute/virtualMachines") {
                    Write-Host "      Found VM: $($resource.Name)" -ForegroundColor Magenta
                    
                    $vmDetails = Get-VMDetails -SubscriptionId $subscription.Id -ResourceGroupName $resource.ResourceGroupName -VMName $resource.Name
                    
                    $vmRecord = [PSCustomObject]@{
                        SubscriptionId = $subscription.Id
                        SubscriptionName = $subscription.Name
                        ResourceGroupName = $resource.ResourceGroupName
                        VNetName = $vnet.Name
                        VMName = $resource.Name
                        VMSize = if ($vmDetails) { $vmDetails.VMSize } else { "Unknown" }
                        OSType = if ($vmDetails) { $vmDetails.OSType } else { "Unknown" }
                        PrivateIPs = if ($vmDetails) { ($vmDetails.NetworkInterfaces | ForEach-Object { $_.PrivateIP }) -join ", " } else { "Unknown" }
                        HasPublicIP = if ($vmDetails) { ($vmDetails.NetworkInterfaces | Where-Object { $_.PublicIP -eq "Yes" }) -ne $null } else { "Unknown" }
                        WorkloadType = $resourceWorkloadType
                        Location = $resource.Location
                        Tags = ($resource.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; "
                    }
                    $vmInventory += $vmRecord
                }
            }
        }
    }
    catch {
        Write-Warning "Error processing subscription $($subscription.Name): $($_.Exception.Message)"
    }
}

# Create output directory if it doesn't exist
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Generate timestamp for file names
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Export results to CSV files
$vnetCsvPath = Join-Path $OutputPath "VNet-Inventory-$timestamp.csv"
$vmCsvPath = Join-Path $OutputPath "VM-Inventory-$timestamp.csv"
$resourceCsvPath = Join-Path $OutputPath "Resource-Inventory-$timestamp.csv"
$summaryCsvPath = Join-Path $OutputPath "Summary-Report-$timestamp.csv"

Write-Host "`nExporting results..." -ForegroundColor Green

# Export VNet inventory
$vnetInventory | Export-Csv -Path $vnetCsvPath -NoTypeInformation
Write-Host "VNet inventory exported to: $vnetCsvPath" -ForegroundColor Green

# Export VM inventory
$vmInventory | Export-Csv -Path $vmCsvPath -NoTypeInformation
Write-Host "VM inventory exported to: $vmCsvPath" -ForegroundColor Green

# Export resource inventory
$resourceInventory | Export-Csv -Path $resourceCsvPath -NoTypeInformation
Write-Host "Resource inventory exported to: $resourceCsvPath" -ForegroundColor Green

# Create summary report
$summary = @()
$totalVNets = $vnetInventory.Count
$totalVMs = $vmInventory.Count
$totalResources = $resourceInventory.Count

$prodVNets = ($vnetInventory | Where-Object { $_.WorkloadType -eq "Production" }).Count
$nonProdVNets = ($vnetInventory | Where-Object { $_.WorkloadType -eq "Non-Production" }).Count
$unknownVNets = ($vnetInventory | Where-Object { $_.WorkloadType -eq "Unknown" }).Count

$prodVMs = ($vmInventory | Where-Object { $_.WorkloadType -eq "Production" }).Count
$nonProdVMs = ($vmInventory | Where-Object { $_.WorkloadType -eq "Non-Production" }).Count
$unknownVMs = ($vmInventory | Where-Object { $_.WorkloadType -eq "Unknown" }).Count

# Group by subscription for summary
$subscriptionSummary = $vnetInventory | Group-Object SubscriptionName | ForEach-Object {
    $subVNets = $_.Group
    $subVMs = $vmInventory | Where-Object { $_.SubscriptionName -eq $_.Name }
    
    [PSCustomObject]@{
        SubscriptionName = $_.Name
        VNetCount = $subVNets.Count
        VMCount = $subVMs.Count
        ProductionVNets = ($subVNets | Where-Object { $_.WorkloadType -eq "Production" }).Count
        NonProductionVNets = ($subVNets | Where-Object { $_.WorkloadType -eq "Non-Production" }).Count
        UnknownVNets = ($subVNets | Where-Object { $_.WorkloadType -eq "Unknown" }).Count
    }
}

$subscriptionSummary | Export-Csv -Path $summaryCsvPath -NoTypeInformation
Write-Host "Summary report exported to: $summaryCsvPath" -ForegroundColor Green

# Display summary
Write-Host "`n=== INVENTORY SUMMARY ===" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor White
Write-Host "Total Subscriptions Processed: $totalSubscriptions" -ForegroundColor White
Write-Host "Total Virtual Networks: $totalVNets" -ForegroundColor White
Write-Host "  - Production: $prodVNets" -ForegroundColor Red
Write-Host "  - Non-Production: $nonProdVNets" -ForegroundColor Green
Write-Host "  - Unknown: $unknownVNets" -ForegroundColor Gray
Write-Host "Total Virtual Machines: $totalVMs" -ForegroundColor White
Write-Host "  - Production: $prodVMs" -ForegroundColor Red
Write-Host "  - Non-Production: $nonProdVMs" -ForegroundColor Green
Write-Host "  - Unknown: $unknownVMs" -ForegroundColor Gray
Write-Host "Total Resources: $totalResources" -ForegroundColor White

Write-Host "`n=== MIGRATION PLANNING RECOMMENDATIONS ===" -ForegroundColor Yellow
Write-Host "Phase 1 - Non-Production VNets: $nonProdVNets VNets identified" -ForegroundColor Green
Write-Host "Phase 2 - Additional Non-Production validation: Review 'Unknown' categorized VNets" -ForegroundColor Yellow
Write-Host "Phase 3 - Production VNets: $prodVNets VNets identified" -ForegroundColor Red

Write-Host "`nFiles created in: $OutputPath" -ForegroundColor Cyan
Write-Host "- VNet Inventory: VNet-Inventory-$timestamp.csv" -ForegroundColor White
Write-Host "- VM Inventory: VM-Inventory-$timestamp.csv" -ForegroundColor White
Write-Host "- Resource Inventory: Resource-Inventory-$timestamp.csv" -ForegroundColor White
Write-Host "- Summary Report: Summary-Report-$timestamp.csv" -ForegroundColor White

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Review the CSV files to identify application teams responsible for each workload" -ForegroundColor White
Write-Host "2. Validate the workload type classifications (Production/Non-Production/Unknown)" -ForegroundColor White
Write-Host "3. Plan migration phases starting with Non-Production VNets" -ForegroundColor White
Write-Host "4. Coordinate with application teams for migration scheduling" -ForegroundColor White
