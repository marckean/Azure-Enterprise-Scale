#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

<#
.SYNOPSIS
    Complete Azure Virtual Network inventory and Virtual WAN migration planning tool - All in One.

.DESCRIPTION
    This comprehensive script performs a complete analysis of your Azure environment to prepare for 
    Virtual WAN migration. It combines workload inventory with network dependency analysis in a single script.

.PARAMETER OutputPath
    Path where all analysis files will be saved. Defaults to current directory.

.PARAMETER Region
    Azure region to focus analysis on. Defaults to "Australia East".

.EXAMPLE
    .\Complete-VirtualWANAnalysis.ps1 -OutputPath "C:\Azure-Migration-Analysis"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\Azure-Migration-Analysis",
    
    [Parameter(Mandatory = $false)]
    [string]$Region = "australiaeast"
)

# Initialize results arrays
$vnetInventory = @()
$vmInventory = @()
$resourceInventory = @()
$peeringInventory = @()
$nsgInventory = @()
$routeTableInventory = @()
$connectivityInventory = @()
$networkServicesInventory = @()

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
        if ($allText -like "*$indicator*") {
            return "Production"
        }
    }
    
    foreach ($indicator in $nonProdIndicators) {
        if ($allText -like "*$indicator*") {
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

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "Created output directory: $OutputPath" -ForegroundColor Green
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

Write-Host "=== AZURE VIRTUAL WAN MIGRATION ANALYSIS ===" -ForegroundColor Cyan
Write-Host "Analysis Date: $(Get-Date)" -ForegroundColor White
Write-Host "Target Region: $Region" -ForegroundColor White
Write-Host "Output Directory: $OutputPath" -ForegroundColor White
Write-Host ""

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Green

# Check Azure PowerShell modules
$requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Network', 'Az.Compute')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Warning "Required module $module is not installed. Please run: Install-Module $module"
        exit 1
    }
}

# Check Azure authentication
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
            $subnets = if ($vnet.Subnets) { $vnet.Subnets } else { @() }
            $subnetInfo = @()
            
            foreach ($subnet in $subnets) {
                $addressPrefix = if ($subnet.AddressPrefix) { $subnet.AddressPrefix -join ", " } else { "Unknown" }
                $connectedDevices = if ($subnet.IpConfigurations) { $subnet.IpConfigurations.Count } else { 0 }
                
                $subnetInfo += @{
                    Name = if ($subnet.Name) { $subnet.Name } else { "Unknown" }
                    AddressPrefix = $addressPrefix
                    ConnectedDevices = $connectedDevices
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
                AddressSpace = if ($vnet.AddressSpace -and $vnet.AddressSpace.AddressPrefixes) { $vnet.AddressSpace.AddressPrefixes -join ", " } else { "Unknown" }
                SubnetCount = $subnets.Count
                SubnetDetails = if ($subnetInfo.Count -gt 0) { ($subnetInfo | ForEach-Object { "$($_.Name) ($($_.AddressPrefix))" }) -join "; " } else { "No subnets" }
                WorkloadType = $workloadType
                DnsServers = if ($vnet.DhcpOptions -and $vnet.DhcpOptions.DnsServers) { $vnet.DhcpOptions.DnsServers -join ", " } else { "Default" }
                Tags = if ($vnet.Tags) { ($vnet.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; " } else { "No tags" }
            }
            $vnetInventory += $vnetRecord
            
            # Analyze VNet Peerings
            if ($vnet.VirtualNetworkPeerings) {
                foreach ($peering in $vnet.VirtualNetworkPeerings) {
                    $remoteVNetName = "Unknown"
                    $remoteSubscription = "Unknown"
                    $remoteResourceGroup = "Unknown"
                    
                    if ($peering.RemoteVirtualNetwork -and $peering.RemoteVirtualNetwork.Id) {
                        $remoteVNetId = $peering.RemoteVirtualNetwork.Id
                        $idParts = $remoteVNetId.Split('/')
                        if ($idParts.Length -ge 9) {
                            $remoteVNetName = $idParts[-1]
                            $remoteSubscription = $idParts[2]
                            $remoteResourceGroup = $idParts[4]
                        }
                    }
                    
                    $peeringRecord = [PSCustomObject]@{
                        SubscriptionId = $subscription.Id
                        SubscriptionName = $subscription.Name
                        ResourceGroupName = $vnet.ResourceGroupName
                        VNetName = $vnet.Name
                        PeeringName = if ($peering.Name) { $peering.Name } else { "Unknown" }
                        PeeringState = if ($peering.PeeringState) { $peering.PeeringState } else { "Unknown" }
                        AllowVnetAccess = if ($null -ne $peering.AllowVirtualNetworkAccess) { $peering.AllowVirtualNetworkAccess } else { "Unknown" }
                        AllowForwardedTraffic = if ($null -ne $peering.AllowForwardedTraffic) { $peering.AllowForwardedTraffic } else { "Unknown" }
                        AllowGatewayTransit = if ($null -ne $peering.AllowGatewayTransit) { $peering.AllowGatewayTransit } else { "Unknown" }
                        UseRemoteGateways = if ($null -ne $peering.UseRemoteGateways) { $peering.UseRemoteGateways } else { "Unknown" }
                        RemoteVNetName = $remoteVNetName
                        RemoteSubscription = $remoteSubscription
                        RemoteResourceGroup = $remoteResourceGroup
                        RemoteVNetId = if ($peering.RemoteVirtualNetwork -and $peering.RemoteVirtualNetwork.Id) { $peering.RemoteVirtualNetwork.Id } else { "Unknown" }
                    }
                    $peeringInventory += $peeringRecord
                }
            }
            
            # Get all resources in the same resource group as the VNet
            try {
                $resources = Get-AzResource -ResourceGroupName $vnet.ResourceGroupName -ErrorAction SilentlyContinue
                if (-not $resources) {
                    $resources = @()
                }
            }
            catch {
                Write-Warning "Could not get resources for resource group $($vnet.ResourceGroupName): $($_.Exception.Message)"
                $resources = @()
            }
            
            # Filter resources that are likely in this VNet
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
                    Tags = if ($resource.Tags) { ($resource.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; " } else { "No tags" }
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
                        PrivateIPs = if ($vmDetails -and $vmDetails.NetworkInterfaces) { ($vmDetails.NetworkInterfaces | ForEach-Object { $_.PrivateIP }) -join ", " } else { "Unknown" }
                        HasPublicIP = if ($vmDetails -and $vmDetails.NetworkInterfaces) { $null -ne ($vmDetails.NetworkInterfaces | Where-Object { $_.PublicIP -eq "Yes" }) } else { "Unknown" }
                        WorkloadType = $resourceWorkloadType
                        Location = $resource.Location
                        Tags = if ($resource.Tags) { ($resource.Tags.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join "; " } else { "No tags" }
                    }
                    $vmInventory += $vmRecord
                }
            }
            
            # Analyze subnets for NSGs and Route Tables
            foreach ($subnet in $vnet.Subnets) {
                # Network Security Groups
                if ($subnet.NetworkSecurityGroup) {
                    try {
                        $nsgId = $subnet.NetworkSecurityGroup.Id
                        $nsgName = $nsgId.Split('/')[-1]
                        $nsgResourceGroup = $nsgId.Split('/')[4]
                        
                        $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $nsgResourceGroup -Name $nsgName -ErrorAction SilentlyContinue
                        if ($nsg) {
                            foreach ($rule in $nsg.SecurityRules) {
                                $nsgRecord = [PSCustomObject]@{
                                    SubscriptionId = $subscription.Id
                                    SubscriptionName = $subscription.Name
                                    VNetName = $vnet.Name
                                    SubnetName = $subnet.Name
                                    NSGName = $nsg.Name
                                    NSGResourceGroup = $nsgResourceGroup
                                    RuleName = $rule.Name
                                    Priority = $rule.Priority
                                    Direction = $rule.Direction
                                    Access = $rule.Access
                                    Protocol = $rule.Protocol
                                    SourcePortRange = $rule.SourcePortRange -join ", "
                                    DestinationPortRange = $rule.DestinationPortRange -join ", "
                                    SourceAddressPrefix = $rule.SourceAddressPrefix -join ", "
                                    DestinationAddressPrefix = $rule.DestinationAddressPrefix -join ", "
                                }
                                $nsgInventory += $nsgRecord
                            }
                        }
                    }
                    catch {
                        Write-Warning "Could not analyze NSG for subnet $($subnet.Name)"
                    }
                }
                
                # Route Tables
                if ($subnet.RouteTable) {
                    try {
                        $routeTableId = $subnet.RouteTable.Id
                        $routeTableName = $routeTableId.Split('/')[-1]
                        $routeTableResourceGroup = $routeTableId.Split('/')[4]
                        
                        $routeTable = Get-AzRouteTable -ResourceGroupName $routeTableResourceGroup -Name $routeTableName -ErrorAction SilentlyContinue
                        if ($routeTable) {
                            foreach ($route in $routeTable.Routes) {
                                $routeRecord = [PSCustomObject]@{
                                    SubscriptionId = $subscription.Id
                                    SubscriptionName = $subscription.Name
                                    VNetName = $vnet.Name
                                    SubnetName = $subnet.Name
                                    RouteTableName = $routeTable.Name
                                    RouteTableResourceGroup = $routeTableResourceGroup
                                    RouteName = $route.Name
                                    AddressPrefix = $route.AddressPrefix
                                    NextHopType = $route.NextHopType
                                    NextHopIpAddress = $route.NextHopIpAddress
                                }
                                $routeTableInventory += $routeRecord
                            }
                        }
                    }
                    catch {
                        Write-Warning "Could not analyze Route Table for subnet $($subnet.Name)"
                    }
                }
            }
            
            # Analyze VPN Gateways and ExpressRoute Gateways
            try {
                $gateways = Get-AzVirtualNetworkGateway -ResourceGroupName $vnet.ResourceGroupName -ErrorAction SilentlyContinue
                foreach ($gateway in $gateways) {
                    if ($gateway.Location -eq $Region) {
                        $connectivityRecord = [PSCustomObject]@{
                            SubscriptionId = $subscription.Id
                            SubscriptionName = $subscription.Name
                            ResourceGroupName = $vnet.ResourceGroupName
                            VNetName = $vnet.Name
                            GatewayName = $gateway.Name
                            GatewayType = if ($gateway.GatewayType) { $gateway.GatewayType } else { "Unknown" }
                            VpnType = if ($gateway.VpnType) { $gateway.VpnType } else { "Unknown" }
                            Sku = if ($gateway.Sku -and $gateway.Sku.Name) { $gateway.Sku.Name } else { "Unknown" }
                            EnableBgp = if ($null -ne $gateway.EnableBgp) { $gateway.EnableBgp } else { "Unknown" }
                            ActiveActive = if ($null -ne $gateway.ActiveActive) { $gateway.ActiveActive } else { "Unknown" }
                            ConnectionCount = (Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $vnet.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { ($_.VirtualNetworkGateway1 -and $_.VirtualNetworkGateway1.Id -eq $gateway.Id) -or ($_.VirtualNetworkGateway2 -and $_.VirtualNetworkGateway2.Id -eq $gateway.Id) }).Count
                        }
                        $connectivityInventory += $connectivityRecord
                    }
                }
            }
            catch {
                Write-Warning "Could not analyze gateways for VNet $($vnet.Name): $($_.Exception.Message)"
            }
        }
        
        # Analyze other network services in the region
        try {
            $loadBalancers = Get-AzLoadBalancer -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $Region }
            foreach ($lb in $loadBalancers) {
                $networkServicesRecord = [PSCustomObject]@{
                    SubscriptionId = $subscription.Id
                    SubscriptionName = $subscription.Name
                    ResourceGroupName = $lb.ResourceGroupName
                    ServiceName = $lb.Name
                    ServiceType = "Load Balancer"
                    Sku = if ($lb.Sku -and $lb.Sku.Name) { $lb.Sku.Name } else { "Unknown" }
                    Location = $lb.Location
                    FrontendIPs = if ($lb.FrontendIpConfigurations) { ($lb.FrontendIpConfigurations | ForEach-Object { $_.PrivateIpAddress } | Where-Object { $_ }) -join ", " } else { "None" }
                    BackendPools = if ($lb.BackendAddressPools) { $lb.BackendAddressPools.Count } else { 0 }
                    Rules = if ($lb.LoadBalancingRules) { $lb.LoadBalancingRules.Count } else { 0 }
                }
                $networkServicesInventory += $networkServicesRecord
            }
        }
        catch {
            Write-Warning "Could not analyze Load Balancers in subscription $($subscription.Name): $($_.Exception.Message)"
        }
        
        try {
            $appGateways = Get-AzApplicationGateway -ErrorAction SilentlyContinue | Where-Object { $_.Location -eq $Region }
            foreach ($appGw in $appGateways) {
                $networkServicesRecord = [PSCustomObject]@{
                    SubscriptionId = $subscription.Id
                    SubscriptionName = $subscription.Name
                    ResourceGroupName = $appGw.ResourceGroupName
                    ServiceName = $appGw.Name
                    ServiceType = "Application Gateway"
                    Sku = if ($appGw.Sku -and $appGw.Sku.Name) { $appGw.Sku.Name } else { "Unknown" }
                    Location = $appGw.Location
                    FrontendIPs = if ($appGw.FrontendIPConfigurations) { ($appGw.FrontendIPConfigurations | ForEach-Object { $_.PrivateIPAddress } | Where-Object { $_ }) -join ", " } else { "None" }
                    BackendPools = if ($appGw.BackendAddressPools) { $appGw.BackendAddressPools.Count } else { 0 }
                    Rules = if ($appGw.RequestRoutingRules) { $appGw.RequestRoutingRules.Count } else { 0 }
                }
                $networkServicesInventory += $networkServicesRecord
            }
        }
        catch {
            Write-Warning "Could not analyze Application Gateways in subscription $($subscription.Name): $($_.Exception.Message)"
        }
    }
    catch {
        Write-Warning "Error processing subscription $($subscription.Name): $($_.Exception.Message)"
    }
}

# Export results to CSV files
Write-Host "`nExporting results..." -ForegroundColor Green

$vnetCsvPath = Join-Path $OutputPath "VNet-Inventory-$timestamp.csv"
$vmCsvPath = Join-Path $OutputPath "VM-Inventory-$timestamp.csv"
$resourceCsvPath = Join-Path $OutputPath "Resource-Inventory-$timestamp.csv"
$peeringCsvPath = Join-Path $OutputPath "VNet-Peering-Analysis-$timestamp.csv"
$nsgCsvPath = Join-Path $OutputPath "NSG-Analysis-$timestamp.csv"
$routeCsvPath = Join-Path $OutputPath "Route-Table-Analysis-$timestamp.csv"
$connectivityCsvPath = Join-Path $OutputPath "Connectivity-Analysis-$timestamp.csv"
$networkServicesCsvPath = Join-Path $OutputPath "Network-Services-Analysis-$timestamp.csv"
$summaryCsvPath = Join-Path $OutputPath "Summary-Report-$timestamp.csv"

# Export all inventories
$vnetInventory | Export-Csv -Path $vnetCsvPath -NoTypeInformation
$vmInventory | Export-Csv -Path $vmCsvPath -NoTypeInformation
$resourceInventory | Export-Csv -Path $resourceCsvPath -NoTypeInformation
$peeringInventory | Export-Csv -Path $peeringCsvPath -NoTypeInformation
$nsgInventory | Export-Csv -Path $nsgCsvPath -NoTypeInformation
$routeTableInventory | Export-Csv -Path $routeCsvPath -NoTypeInformation
$connectivityInventory | Export-Csv -Path $connectivityCsvPath -NoTypeInformation
$networkServicesInventory | Export-Csv -Path $networkServicesCsvPath -NoTypeInformation

Write-Host "All inventories exported successfully!" -ForegroundColor Green

# Create summary statistics
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

# Generate migration planning report
$reportContent = @"
# Azure Virtual WAN Migration Planning Report
**Generated:** $(Get-Date)
**Region:** $Region
**Analysis Scope:** All subscriptions in tenant

## Executive Summary

This analysis has identified **$totalVNets virtual networks** across **$(($vnetInventory | Select-Object SubscriptionName -Unique).Count) subscriptions** in the $Region region, containing **$totalVMs virtual machines** and supporting various workloads.

### Workload Classification
- **Production VNets:** $prodVNets
- **Non-Production VNets:** $nonProdVNets
- **Unknown Classification:** $unknownVNets

### Migration Risk Assessment
- **VNet Peerings:** $($peeringInventory.Count) peering relationships identified
- **Gateway Dependencies:** $(($peeringInventory | Where-Object { $_.UseRemoteGateways -eq 'True' -or $_.AllowGatewayTransit -eq 'True' }).Count) VNets with gateway dependencies
- **Hybrid Connectivity:** $($connectivityInventory.Count) VPN/ExpressRoute gateways

## Recommended Migration Phases

### Phase 1: Non-Production VNets (Pilot)
**Target:** $nonProdVNets VNets
**Risk Level:** Low
**Estimated Duration:** 2-4 weeks

Non-production workloads identified for initial migration:
$(($vnetInventory | Where-Object { $_.WorkloadType -eq 'Non-Production' } | Select-Object -First 10 | ForEach-Object { "- $($_.VNetName) ($($_.SubscriptionName))" }) -join "`n")
$(if ($nonProdVNets -gt 10) { "... and $($nonProdVNets - 10) more" })

### Phase 2: Unknown Classification Review
**Target:** $unknownVNets VNets
**Risk Level:** Medium
**Action Required:** Manual classification and stakeholder identification

VNets requiring classification:
$(($vnetInventory | Where-Object { $_.WorkloadType -eq 'Unknown' } | Select-Object -First 10 | ForEach-Object { "- $($_.VNetName) ($($_.SubscriptionName))" }) -join "`n")
$(if ($unknownVNets -gt 10) { "... and $($unknownVNets - 10) more" })

### Phase 3: Production VNets
**Target:** $prodVNets VNets
**Risk Level:** High
**Estimated Duration:** 6-12 weeks

Critical production workloads requiring careful planning:
$(($vnetInventory | Where-Object { $_.WorkloadType -eq 'Production' } | Select-Object -First 10 | ForEach-Object { "- $($_.VNetName) ($($_.SubscriptionName))" }) -join "`n")
$(if ($prodVNets -gt 10) { "... and $($prodVNets - 10) more" })

## Critical Dependencies and Blockers

### VNet Peering Dependencies
$(if ($peeringInventory.Count -gt 0) {
    $criticalPeerings = $peeringInventory | Where-Object { $_.UseRemoteGateways -eq 'True' -or $_.AllowGatewayTransit -eq 'True' }
    if ($criticalPeerings.Count -gt 0) {
        "**High Priority:** $($criticalPeerings.Count) VNets have gateway transit dependencies that must be addressed before migration:`n" +
        (($criticalPeerings | ForEach-Object { "- $($_.VNetName) → $($_.RemoteVNetName) (Transit: $($_.AllowGatewayTransit), UseRemote: $($_.UseRemoteGateways))" }) -join "`n")
    } else {
        "No critical gateway dependencies identified."
    }
} else {
    "No VNet peerings found in analysis."
})

### Hybrid Connectivity
$(if ($connectivityInventory.Count -gt 0) {
    "**Existing Gateways:** $($connectivityInventory.Count) gateways require migration planning:`n" +
    (($connectivityInventory | ForEach-Object { "- $($_.GatewayName) ($($_.GatewayType)) in $($_.VNetName)" }) -join "`n")
} else {
    "No hybrid connectivity gateways identified."
})

## Application Team Mapping

The following subscriptions and VNets require application team identification:

$(($vnetInventory | Group-Object SubscriptionName | ForEach-Object { 
    "### $($_.Name)`n" +
    (($_.Group | ForEach-Object { "- **$($_.VNetName)** ($($_.WorkloadType)) - $($_.SubnetCount) subnets, $($_.AddressSpace)" }) -join "`n") + "`n"
}) -join "`n")

## Files Generated

This analysis has created the following detailed inventory files:
- VNet-Inventory-$timestamp.csv - Complete virtual network inventory
- VM-Inventory-$timestamp.csv - Virtual machine details and locations
- Resource-Inventory-$timestamp.csv - All resources within VNets
- VNet-Peering-Analysis-$timestamp.csv - Network peering relationships
- Connectivity-Analysis-$timestamp.csv - VPN/ExpressRoute gateway analysis
- NSG-Analysis-$timestamp.csv - Network Security Group rules
- Route-Table-Analysis-$timestamp.csv - Custom routing configuration
- Network-Services-Analysis-$timestamp.csv - Load balancers and app gateways
- Summary-Report-$timestamp.csv - High-level statistics

Review these files for detailed planning and coordination with application teams.
"@

$reportPath = Join-Path $OutputPath "Virtual-WAN-Migration-Plan-$timestamp.md"
$reportContent | Out-File -FilePath $reportPath -Encoding UTF8

# Display summary
Write-Host "`n=== ANALYSIS COMPLETE ===" -ForegroundColor Green
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
Write-Host "Migration planning report: Virtual-WAN-Migration-Plan-$timestamp.md" -ForegroundColor Green

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Review the CSV files to identify application teams responsible for each workload" -ForegroundColor White
Write-Host "2. Validate the workload type classifications (Production/Non-Production/Unknown)" -ForegroundColor White
Write-Host "3. Plan migration phases starting with Non-Production VNets" -ForegroundColor White
Write-Host "4. Coordinate with application teams for migration scheduling" -ForegroundColor White

# Open the output directory if on Windows
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    try {
        Start-Process explorer.exe -ArgumentList $OutputPath
        Write-Host "`nOpened output directory in Explorer" -ForegroundColor Green
    } catch {
        Write-Host "Output directory: $OutputPath" -ForegroundColor Cyan
    }
}
