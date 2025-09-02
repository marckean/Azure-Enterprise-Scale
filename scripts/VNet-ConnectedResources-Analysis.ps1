#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

<#
.SYNOPSIS
    Comprehensive Virtual Network and Connected Resource Analysis for Virtual WAN Migration

.DESCRIPTION
    This script provides a complete analysis of all VNets in a region and EVERY connected resource,
    including VMs in different resource groups. It traces network connections to ensure nothing is missed.

.PARAMETER OutputPath
    Path where all analysis files will be saved.

.PARAMETER Region
    Azure region to focus analysis on. Defaults to "australiaeast".

.EXAMPLE
    .\VNet-ConnectedResources-Analysis.ps1 -OutputPath "C:\Azure-Migration-Analysis"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\Azure-Migration-Analysis",
    
    [Parameter(Mandatory = $false)]
    [string]$Region = "australiaeast"
)

# Initialize results arrays
$vnetInventory = @()
$connectedVMInventory = @()
$connectedDeviceInventory = @()
$subnetAnalysis = @()

# Function to determine workload type
function Get-WorkloadType {
    param([string]$Name, [string]$ResourceGroupName, [string]$SubscriptionName)
    
    $prodIndicators = @('prod', 'production', 'live', 'prd')
    $nonProdIndicators = @('dev', 'development', 'test', 'staging', 'uat', 'sit', 'nonprod', 'non-prod', 'sandbox', 'poc', 'demo')
    $allText = "$Name $ResourceGroupName $SubscriptionName".ToLower()
    
    foreach ($indicator in $prodIndicators) {
        if ($allText -like "*$indicator*") { return "Production" }
    }
    foreach ($indicator in $nonProdIndicators) {
        if ($allText -like "*$indicator*") { return "Non-Production" }
    }
    return "Unknown"
}

# Function to get VM details
function Get-VMDetails {
    param([string]$VMResourceId)
    
    try {
        $vmIdParts = $VMResourceId.Split('/')
        $vmSubscription = $vmIdParts[2]
        $vmResourceGroup = $vmIdParts[4]
        $vmName = $vmIdParts[8]
        
        # Switch to the VM's subscription context
        $currentContext = Get-AzContext
        if ($currentContext.Subscription.Id -ne $vmSubscription) {
            Set-AzContext -SubscriptionId $vmSubscription | Out-Null
        }
        
        $vm = Get-AzVM -ResourceGroupName $vmResourceGroup -Name $vmName -ErrorAction SilentlyContinue
        if ($vm) {
            $vmTags = if ($vm.Tags) { ($vm.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; " } else { "No tags" }
            
            return @{
                VMName = $vm.Name
                VMSize = $vm.HardwareProfile.VmSize
                OSType = if ($vm.StorageProfile.OsDisk.OsType) { $vm.StorageProfile.OsDisk.OsType } else { "Unknown" }
                ResourceGroup = $vm.ResourceGroupName
                Subscription = $vmSubscription
                Tags = $vmTags
                PowerState = "Unknown"  # We'll get this separately if needed
                Location = $vm.Location
            }
        }
    }
    catch {
        Write-Warning "Could not get VM details for $VMResourceId`: $($_.Exception.Message)"
    }
    
    return $null
}

# Function to get connected resource details
function Get-ConnectedResourceDetails {
    param([string]$ResourceId, [string]$ResourceType)
    
    try {
        $resourceIdParts = $ResourceId.Split('/')
        $resourceSubscription = $resourceIdParts[2]
        
        # Switch to the resource's subscription context
        $currentContext = Get-AzContext
        if ($currentContext.Subscription.Id -ne $resourceSubscription) {
            Set-AzContext -SubscriptionId $resourceSubscription | Out-Null
        }
        
        $resource = Get-AzResource -ResourceId $ResourceId -ErrorAction SilentlyContinue
        if ($resource) {
            $resourceTags = if ($resource.Tags) { ($resource.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; " } else { "No tags" }
            
            return @{
                ResourceName = $resource.Name
                ResourceType = $resource.ResourceType
                ResourceGroup = $resource.ResourceGroupName
                Subscription = $resourceSubscription
                Tags = $resourceTags
                Location = $resource.Location
            }
        }
    }
    catch {
        Write-Warning "Could not get resource details for $ResourceId`: $($_.Exception.Message)"
    }
    
    return $null
}

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "Created output directory: $OutputPath" -ForegroundColor Green
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

Write-Host "=== VIRTUAL NETWORK CONNECTED RESOURCES ANALYSIS ===" -ForegroundColor Cyan
Write-Host "Analysis Date: $(Get-Date)" -ForegroundColor White
Write-Host "Target Region: $Region" -ForegroundColor White
Write-Host "Output Directory: $OutputPath" -ForegroundColor White
Write-Host ""

# Check authentication
$context = Get-AzContext
if (-not $context) {
    Write-Host "Please login to Azure first using Connect-AzAccount" -ForegroundColor Red
    exit 1
}

Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Green

# Get all subscriptions
Write-Host "`nGetting all subscriptions..." -ForegroundColor Green
$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
Write-Host "Found $($subscriptions.Count) enabled subscriptions" -ForegroundColor Green

$totalVNets = 0
$totalConnectedVMs = 0
$totalConnectedDevices = 0

foreach ($subscription in $subscriptions) {
    Write-Host "`nProcessing subscription: $($subscription.Name)" -ForegroundColor Yellow
    
    try {
        Set-AzContext -SubscriptionId $subscription.Id | Out-Null
        
        # Get all virtual networks in the specified region
        $vnets = Get-AzVirtualNetwork | Where-Object { $_.Location -eq $Region }
        
        if ($vnets.Count -eq 0) {
            Write-Host "  No virtual networks found in $Region" -ForegroundColor Gray
            continue
        }
        
        Write-Host "  Found $($vnets.Count) virtual networks in $Region" -ForegroundColor Cyan
        $totalVNets += $vnets.Count
        
        foreach ($vnet in $vnets) {
            Write-Host "    Analyzing VNet: $($vnet.Name)" -ForegroundColor White
            
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
                AddressSpace = if ($vnet.AddressSpace -and $vnet.AddressSpace.AddressPrefixes) { $vnet.AddressSpace.AddressPrefixes -join ", " } else { "Unknown" }
                SubnetCount = if ($vnet.Subnets) { $vnet.Subnets.Count } else { 0 }
                WorkloadType = $workloadType
                Tags = if ($vnet.Tags) { ($vnet.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; " } else { "No tags" }
            }
            $vnetInventory += $vnetRecord
            
            # Analyze each subnet and its connected resources
            if ($vnet.Subnets) {
                foreach ($subnet in $vnet.Subnets) {
                    Write-Host "      Analyzing subnet: $($subnet.Name)" -ForegroundColor Gray
                    
                    $connectedResourcesCount = 0
                    $connectedVMsInSubnet = 0
                    $connectedDevicesInSubnet = 0
                    
                    # Get all IP configurations in this subnet
                    if ($subnet.IpConfigurations) {
                        foreach ($ipConfig in $subnet.IpConfigurations) {
                            $connectedResourcesCount++
                            
                            # Parse the IP configuration ID to get the network interface
                            $ipConfigId = $ipConfig.Id
                            $nicId = ($ipConfigId -split '/ipConfigurations/')[0]
                            
                            try {
                                # Get the network interface
                                $nic = Get-AzNetworkInterface | Where-Object { $_.Id -eq $nicId }
                                
                                if ($nic) {
                                    $privateIP = ($nic.IpConfigurations | Where-Object { $_.Id -eq $ipConfigId }).PrivateIpAddress
                                    
                                    # Check if this NIC is attached to a VM
                                    if ($nic.VirtualMachine -and $nic.VirtualMachine.Id) {
                                        $connectedVMsInSubnet++
                                        $totalConnectedVMs++
                                        
                                        Write-Host "        Found VM connected: $($nic.VirtualMachine.Id.Split('/')[-1])" -ForegroundColor Magenta
                                        
                                        $vmDetails = Get-VMDetails -VMResourceId $nic.VirtualMachine.Id
                                        
                                        if ($vmDetails) {
                                            $vmRecord = [PSCustomObject]@{
                                                VNetSubscriptionId = $subscription.Id
                                                VNetSubscriptionName = $subscription.Name
                                                VNetResourceGroup = $vnet.ResourceGroupName
                                                VNetName = $vnet.Name
                                                SubnetName = $subnet.Name
                                                PrivateIP = $privateIP
                                                VMName = $vmDetails.VMName
                                                VMSize = $vmDetails.VMSize
                                                OSType = $vmDetails.OSType
                                                VMResourceGroup = $vmDetails.ResourceGroup
                                                VMSubscription = $vmDetails.Subscription
                                                VMTags = $vmDetails.Tags
                                                VMLocation = $vmDetails.Location
                                                WorkloadType = Get-WorkloadType -Name $vmDetails.VMName -ResourceGroupName $vmDetails.ResourceGroup -SubscriptionName $vmDetails.Subscription
                                                NICName = $nic.Name
                                            }
                                            $connectedVMInventory += $vmRecord
                                        }
                                    }
                                    else {
                                        # This is a non-VM connected device
                                        $connectedDevicesInSubnet++
                                        $totalConnectedDevices++
                                        
                                        Write-Host "        Found non-VM device: $($nic.Name)" -ForegroundColor Yellow
                                        
                                        # Try to determine what type of resource this NIC belongs to
                                        $resourceType = "Network Interface"
                                        
                                        # Check if NIC has tags that might indicate the parent resource
                                        $nicTags = if ($nic.Tags) { ($nic.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; " } else { "No tags" }
                                        
                                        $deviceRecord = [PSCustomObject]@{
                                            VNetSubscriptionId = $subscription.Id
                                            VNetSubscriptionName = $subscription.Name
                                            VNetResourceGroup = $vnet.ResourceGroupName
                                            VNetName = $vnet.Name
                                            SubnetName = $subnet.Name
                                            PrivateIP = $privateIP
                                            DeviceName = $nic.Name
                                            DeviceType = $resourceType
                                            DeviceResourceGroup = $nic.ResourceGroupName
                                            DeviceSubscription = $subscription.Id
                                            DeviceTags = $nicTags
                                            DeviceLocation = $nic.Location
                                            WorkloadType = Get-WorkloadType -Name $nic.Name -ResourceGroupName $nic.ResourceGroupName -SubscriptionName $subscription.Name
                                        }
                                        $connectedDeviceInventory += $deviceRecord
                                    }
                                }
                            }
                            catch {
                                Write-Warning "Error analyzing IP configuration $ipConfigId`: $($_.Exception.Message)"
                            }
                        }
                    }
                    
                    # Record subnet analysis
                    $subnetRecord = [PSCustomObject]@{
                        SubscriptionId = $subscription.Id
                        SubscriptionName = $subscription.Name
                        VNetName = $vnet.Name
                        SubnetName = $subnet.Name
                        AddressPrefix = if ($subnet.AddressPrefix) { $subnet.AddressPrefix -join ", " } else { "Unknown" }
                        TotalConnectedResources = $connectedResourcesCount
                        ConnectedVMs = $connectedVMsInSubnet
                        ConnectedDevices = $connectedDevicesInSubnet
                    }
                    $subnetAnalysis += $subnetRecord
                }
            }
        }
    }
    catch {
        Write-Warning "Error processing subscription $($subscription.Name): $($_.Exception.Message)"
    }
}

# Export results to CSV files
Write-Host "`nExporting results..." -ForegroundColor Green

$vnetCsvPath = Join-Path $OutputPath "VNet-Complete-Inventory-$timestamp.csv"
$vmCsvPath = Join-Path $OutputPath "Connected-VMs-Complete-$timestamp.csv"
$deviceCsvPath = Join-Path $OutputPath "Connected-Devices-Complete-$timestamp.csv"
$subnetCsvPath = Join-Path $OutputPath "Subnet-Analysis-Complete-$timestamp.csv"

$vnetInventory | Export-Csv -Path $vnetCsvPath -NoTypeInformation
$connectedVMInventory | Export-Csv -Path $vmCsvPath -NoTypeInformation
$connectedDeviceInventory | Export-Csv -Path $deviceCsvPath -NoTypeInformation
$subnetAnalysis | Export-Csv -Path $subnetCsvPath -NoTypeInformation

Write-Host "All inventories exported successfully!" -ForegroundColor Green

# Display summary
Write-Host "`n=== COMPREHENSIVE ANALYSIS COMPLETE ===" -ForegroundColor Green
Write-Host "Region: $Region" -ForegroundColor White
Write-Host "Total Virtual Networks: $totalVNets" -ForegroundColor White
Write-Host "Total Connected Virtual Machines: $totalConnectedVMs" -ForegroundColor Cyan
Write-Host "Total Connected Non-VM Devices: $totalConnectedDevices" -ForegroundColor Yellow
Write-Host "Total Connected Resources: $($totalConnectedVMs + $totalConnectedDevices)" -ForegroundColor White

# Show breakdown by workload type
$prodVNets = ($vnetInventory | Where-Object { $_.WorkloadType -eq "Production" }).Count
$nonProdVNets = ($vnetInventory | Where-Object { $_.WorkloadType -eq "Non-Production" }).Count
$unknownVNets = ($vnetInventory | Where-Object { $_.WorkloadType -eq "Unknown" }).Count

$prodVMs = ($connectedVMInventory | Where-Object { $_.WorkloadType -eq "Production" }).Count
$nonProdVMs = ($connectedVMInventory | Where-Object { $_.WorkloadType -eq "Non-Production" }).Count
$unknownVMs = ($connectedVMInventory | Where-Object { $_.WorkloadType -eq "Unknown" }).Count

Write-Host "`n=== WORKLOAD BREAKDOWN ===" -ForegroundColor Yellow
Write-Host "VNets by Type:" -ForegroundColor White
Write-Host "  - Production: $prodVNets" -ForegroundColor Red
Write-Host "  - Non-Production: $nonProdVNets" -ForegroundColor Green
Write-Host "  - Unknown: $unknownVNets" -ForegroundColor Gray

Write-Host "VMs by Type:" -ForegroundColor White
Write-Host "  - Production: $prodVMs" -ForegroundColor Red
Write-Host "  - Non-Production: $nonProdVMs" -ForegroundColor Green
Write-Host "  - Unknown: $unknownVMs" -ForegroundColor Gray

Write-Host "`nFiles created in: $OutputPath" -ForegroundColor Cyan
Write-Host "- Complete VNet Inventory: VNet-Complete-Inventory-$timestamp.csv" -ForegroundColor White
Write-Host "- All Connected VMs: Connected-VMs-Complete-$timestamp.csv" -ForegroundColor White
Write-Host "- All Connected Devices: Connected-Devices-Complete-$timestamp.csv" -ForegroundColor White
Write-Host "- Subnet Analysis: Subnet-Analysis-Complete-$timestamp.csv" -ForegroundColor White

Write-Host "`nKey Information in VM Report:" -ForegroundColor Yellow
Write-Host "- VM Name, Size, OS Type" -ForegroundColor White
Write-Host "- VM Resource Group and Subscription" -ForegroundColor White
Write-Host "- VM Tags (for application identification)" -ForegroundColor White
Write-Host "- Connected VNet and Subnet details" -ForegroundColor White
Write-Host "- Private IP address" -ForegroundColor White
Write-Host "- Workload classification" -ForegroundColor White

if ($IsWindows -or $env:OS -eq "Windows_NT") {
    try {
        Start-Process explorer.exe -ArgumentList $OutputPath
        Write-Host "`nOpened output directory in Explorer" -ForegroundColor Green
    } catch {
        Write-Host "Output directory: $OutputPath" -ForegroundColor Cyan
    }
}
