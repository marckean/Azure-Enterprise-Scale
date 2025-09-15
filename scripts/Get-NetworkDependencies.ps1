#Requires -Modules Az.Accounts, Az.Resources, Az.Network

<#
.SYNOPSIS
    Analyzes network connectivity and dependencies for Virtual WAN migration planning.

.DESCRIPTION
    This supplementary script provides detailed network topology analysis including:
    - VNet peering relationships
    - Network Security Groups and rules
    - Route tables and custom routes
    - VPN/ExpressRoute connections
    - Load balancers and application gateways
    - Service endpoints and private endpoints
    
    This information is critical for understanding dependencies before migrating to Virtual WAN.

.PARAMETER OutputPath
    Path where the CSV files will be saved. Defaults to current directory.

.PARAMETER Region
    Azure region to focus on. Defaults to "Australia East".

.EXAMPLE
    .\Get-NetworkDependencies.ps1 -OutputPath "C:\temp\azure-inventory"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",
    
    [Parameter(Mandatory = $false)]
    [string]$Region = "Australia East"
)

# Initialize results arrays
$peeringInventory = @()
$nsgInventory = @()
$routeTableInventory = @()
$connectivityInventory = @()
$networkServicesInventory = @()

Write-Host "Analyzing network dependencies for Virtual WAN migration..." -ForegroundColor Green

# Check if user is logged in
$context = Get-AzContext
if (-not $context) {
    Write-Host "Please login to Azure first using Connect-AzAccount" -ForegroundColor Red
    exit 1
}

# Get all subscriptions
$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
$totalSubscriptions = $subscriptions.Count
$currentSubscription = 0

foreach ($subscription in $subscriptions) {
    $currentSubscription++
    Write-Host "`n[$currentSubscription/$totalSubscriptions] Analyzing subscription: $($subscription.Name)" -ForegroundColor Yellow
    
    try {
        Set-AzContext -SubscriptionId $subscription.Id | Out-Null
        
        # Get all virtual networks in the region
        $vnets = Get-AzVirtualNetwork | Where-Object { $_.Location -eq $Region }
        
        foreach ($vnet in $vnets) {
            Write-Host "  Analyzing VNet: $($vnet.Name)" -ForegroundColor Cyan
            
            # Analyze VNet Peerings with enhanced validation
            foreach ($peering in $vnet.VirtualNetworkPeerings) {
                $remoteVNetName = "Unknown"
                $remoteSubscription = "Unknown"
                $remoteResourceGroup = "Unknown"
                $validationStatus = "Not Validated"
                $validationMessage = "No remote VNet ID available"
                
                if ($peering.RemoteVirtualNetwork.Id) {
                    $remoteVNetId = $peering.RemoteVirtualNetwork.Id
                    $remoteVNetName = $remoteVNetId.Split('/')[-1]
                    $remoteSubscription = $remoteVNetId.Split('/')[2]
                    $remoteResourceGroup = $remoteVNetId.Split('/')[4]
                    
                    # Enhanced validation: Check if remote VNet exists and is accessible
                    try {
                        $originalContext = Get-AzContext
                        
                        # Only try to validate if it's a different subscription
                        if ($remoteSubscription -ne $subscription.Id) {
                            try {
                                # Try to switch to remote subscription context
                                $remoteContext = Set-AzContext -SubscriptionId $remoteSubscription -ErrorAction SilentlyContinue
                                if ($remoteContext) {
                                    # Try to get the remote VNet
                                    $remoteVNet = Get-AzVirtualNetwork -ResourceGroupName $remoteResourceGroup -Name $remoteVNetName -ErrorAction SilentlyContinue
                                    if ($remoteVNet) {
                                        $validationStatus = "Validated"
                                        $validationMessage = "Remote VNet exists and is accessible"
                                    } else {
                                        # Check if resource group exists to differentiate access vs existence issues
                                        $remoteRG = Get-AzResourceGroup -Name $remoteResourceGroup -ErrorAction SilentlyContinue
                                        if ($remoteRG) {
                                            $validationStatus = "Not Found"
                                            $validationMessage = "VNet $remoteVNetName not found in resource group $remoteResourceGroup. May have been deleted or renamed."
                                        } else {
                                            $validationStatus = "Access Denied"
                                            $validationMessage = "Cannot access resource group $remoteResourceGroup in subscription $remoteSubscription"
                                        }
                                    }
                                } else {
                                    $validationStatus = "Access Denied"
                                    $validationMessage = "Cannot access subscription $remoteSubscription. Check permissions."
                                }
                            }
                            catch {
                                if ($_.Exception.Message -like "*AuthorizationFailed*" -or 
                                    $_.Exception.Message -like "*Forbidden*" -or 
                                    $_.Exception.Message -like "*insufficient privileges*") {
                                    $validationStatus = "Access Denied"
                                    $validationMessage = "Insufficient permissions to access subscription $remoteSubscription"
                                } else {
                                    $validationStatus = "Error"
                                    $validationMessage = "Error validating remote VNet: $($_.Exception.Message)"
                                }
                            }
                            finally {
                                # Restore original context
                                if ($originalContext) {
                                    Set-AzContext -Context $originalContext | Out-Null
                                }
                            }
                        } else {
                            # Same subscription - try direct validation
                            try {
                                $remoteVNet = Get-AzVirtualNetwork -ResourceGroupName $remoteResourceGroup -Name $remoteVNetName -ErrorAction SilentlyContinue
                                if ($remoteVNet) {
                                    $validationStatus = "Validated"
                                    $validationMessage = "Remote VNet exists in same subscription"
                                } else {
                                    $validationStatus = "Not Found"
                                    $validationMessage = "VNet $remoteVNetName not found in resource group $remoteResourceGroup in same subscription"
                                }
                            }
                            catch {
                                $validationStatus = "Error"
                                $validationMessage = "Error validating remote VNet in same subscription: $($_.Exception.Message)"
                            }
                        }
                        
                        # Log appropriate message based on validation result
                        if ($validationStatus -eq "Access Denied") {
                            Write-Host "    ⚠️  Access denied to remote VNet $remoteVNetName in subscription $remoteSubscription - this may be expected for cross-tenant or restricted subscriptions" -ForegroundColor Yellow
                        } elseif ($validationStatus -eq "Not Found") {
                            Write-Warning "    ❌ VNet $remoteVNetName not found in subscription $remoteSubscription, resource group $remoteResourceGroup. This may indicate a stale peering link."
                        } elseif ($validationStatus -eq "Validated") {
                            Write-Host "    ✅ Remote VNet $remoteVNetName validated successfully" -ForegroundColor Green
                        }
                    }
                    catch {
                        $validationStatus = "Error"
                        $validationMessage = "Unexpected error during validation: $($_.Exception.Message)"
                        Write-Warning "    Error validating remote VNet $remoteVNetName`: $($_.Exception.Message)"
                    }
                }
                
                $peeringRecord = [PSCustomObject]@{
                    SubscriptionId = $subscription.Id
                    SubscriptionName = $subscription.Name
                    ResourceGroupName = $vnet.ResourceGroupName
                    VNetName = $vnet.Name
                    PeeringName = $peering.Name
                    PeeringState = $peering.PeeringState
                    AllowVnetAccess = $peering.AllowVirtualNetworkAccess
                    AllowForwardedTraffic = $peering.AllowForwardedTraffic
                    AllowGatewayTransit = $peering.AllowGatewayTransit
                    UseRemoteGateways = $peering.UseRemoteGateways
                    RemoteVNetName = $remoteVNetName
                    RemoteSubscription = $remoteSubscription
                    RemoteResourceGroup = $remoteResourceGroup
                    RemoteVNetId = $peering.RemoteVirtualNetwork.Id
                    ValidationStatus = $validationStatus
                    ValidationMessage = $validationMessage
                    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                }
                $peeringInventory += $peeringRecord
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
            $gateways = Get-AzVirtualNetworkGateway -ResourceGroupName $vnet.ResourceGroupName -ErrorAction SilentlyContinue
            foreach ($gateway in $gateways) {
                if ($gateway.Location -eq $Region) {
                    $connectivityRecord = [PSCustomObject]@{
                        SubscriptionId = $subscription.Id
                        SubscriptionName = $subscription.Name
                        ResourceGroupName = $vnet.ResourceGroupName
                        VNetName = $vnet.Name
                        GatewayName = $gateway.Name
                        GatewayType = $gateway.GatewayType
                        VpnType = $gateway.VpnType
                        Sku = $gateway.Sku.Name
                        EnableBgp = $gateway.EnableBgp
                        ActiveActive = $gateway.ActiveActive
                        ConnectionCount = (Get-AzVirtualNetworkGatewayConnection -ResourceGroupName $vnet.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.VirtualNetworkGateway1.Id -eq $gateway.Id -or $_.VirtualNetworkGateway2.Id -eq $gateway.Id }).Count
                    }
                    $connectivityInventory += $connectivityRecord
                }
            }
        }
        
        # Analyze other network services in the region
        $loadBalancers = Get-AzLoadBalancer | Where-Object { $_.Location -eq $Region }
        foreach ($lb in $loadBalancers) {
            $networkServicesRecord = [PSCustomObject]@{
                SubscriptionId = $subscription.Id
                SubscriptionName = $subscription.Name
                ResourceGroupName = $lb.ResourceGroupName
                ServiceName = $lb.Name
                ServiceType = "Load Balancer"
                Sku = $lb.Sku.Name
                Location = $lb.Location
                FrontendIPs = ($lb.FrontendIpConfigurations | ForEach-Object { $_.PrivateIpAddress }) -join ", "
                BackendPools = $lb.BackendAddressPools.Count
                Rules = $lb.LoadBalancingRules.Count
            }
            $networkServicesInventory += $networkServicesRecord
        }
        
        $appGateways = Get-AzApplicationGateway | Where-Object { $_.Location -eq $Region }
        foreach ($appGw in $appGateways) {
            $networkServicesRecord = [PSCustomObject]@{
                SubscriptionId = $subscription.Id
                SubscriptionName = $subscription.Name
                ResourceGroupName = $appGw.ResourceGroupName
                ServiceName = $appGw.Name
                ServiceType = "Application Gateway"
                Sku = $appGw.Sku.Name
                Location = $appGw.Location
                FrontendIPs = ($appGw.FrontendIPConfigurations | ForEach-Object { $_.PrivateIPAddress }) -join ", "
                BackendPools = $appGw.BackendAddressPools.Count
                Rules = $appGw.RequestRoutingRules.Count
            }
            $networkServicesInventory += $networkServicesRecord
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
$peeringCsvPath = Join-Path $OutputPath "VNet-Peering-Analysis-$timestamp.csv"
$nsgCsvPath = Join-Path $OutputPath "NSG-Analysis-$timestamp.csv"
$routeCsvPath = Join-Path $OutputPath "Route-Table-Analysis-$timestamp.csv"
$connectivityCsvPath = Join-Path $OutputPath "Connectivity-Analysis-$timestamp.csv"
$networkServicesCsvPath = Join-Path $OutputPath "Network-Services-Analysis-$timestamp.csv"

Write-Host "`nExporting network dependency analysis..." -ForegroundColor Green

$peeringInventory | Export-Csv -Path $peeringCsvPath -NoTypeInformation
Write-Host "VNet peering analysis exported to: $peeringCsvPath" -ForegroundColor Green

$nsgInventory | Export-Csv -Path $nsgCsvPath -NoTypeInformation
Write-Host "NSG analysis exported to: $nsgCsvPath" -ForegroundColor Green

$routeTableInventory | Export-Csv -Path $routeCsvPath -NoTypeInformation
Write-Host "Route table analysis exported to: $routeCsvPath" -ForegroundColor Green

$connectivityInventory | Export-Csv -Path $connectivityCsvPath -NoTypeInformation
Write-Host "Connectivity analysis exported to: $connectivityCsvPath" -ForegroundColor Green

$networkServicesInventory | Export-Csv -Path $networkServicesCsvPath -NoTypeInformation
Write-Host "Network services analysis exported to: $networkServicesCsvPath" -ForegroundColor Green

# Display dependency summary
Write-Host "`n=== NETWORK DEPENDENCY ANALYSIS ===" -ForegroundColor Yellow
Write-Host "VNet Peerings Found: $($peeringInventory.Count)" -ForegroundColor White
Write-Host "NSG Rules Analyzed: $($nsgInventory.Count)" -ForegroundColor White
Write-Host "Custom Routes Found: $($routeTableInventory.Count)" -ForegroundColor White
Write-Host "Gateways Found: $($connectivityInventory.Count)" -ForegroundColor White
Write-Host "Network Services Found: $($networkServicesInventory.Count)" -ForegroundColor White

# Peering validation summary
if ($peeringInventory.Count -gt 0) {
    $validatedPeerings = ($peeringInventory | Where-Object { $_.ValidationStatus -eq "Validated" }).Count
    $accessDeniedPeerings = ($peeringInventory | Where-Object { $_.ValidationStatus -eq "Access Denied" }).Count
    $notFoundPeerings = ($peeringInventory | Where-Object { $_.ValidationStatus -eq "Not Found" }).Count
    $errorPeerings = ($peeringInventory | Where-Object { $_.ValidationStatus -eq "Error" }).Count
    
    Write-Host "`n=== PEERING VALIDATION SUMMARY ===" -ForegroundColor Cyan
    Write-Host "Successfully validated: $validatedPeerings" -ForegroundColor Green
    Write-Host "Access denied: $accessDeniedPeerings" -ForegroundColor Yellow
    Write-Host "Not found (potentially stale): $notFoundPeerings" -ForegroundColor Red
    Write-Host "Validation errors: $errorPeerings" -ForegroundColor Magenta
    
    if ($accessDeniedPeerings -gt 0) {
        Write-Host "`n⚠️  Some remote VNets could not be validated due to access permissions." -ForegroundColor Yellow
        Write-Host "This is often expected for cross-tenant or restricted subscription scenarios." -ForegroundColor White
    }
    
    if ($notFoundPeerings -gt 0) {
        Write-Host "`n❌ Some remote VNets appear to be missing and may represent stale peering links." -ForegroundColor Red
        Write-Host "Consider reviewing and removing these stale peerings." -ForegroundColor White
    }
}

# Critical dependencies for Virtual WAN migration
$criticalPeerings = $peeringInventory | Where-Object { $_.UseRemoteGateways -eq $true -or $_.AllowGatewayTransit -eq $true }
$customRoutes = $routeTableInventory | Where-Object { $_.NextHopType -ne "Internet" -and $_.NextHopType -ne "VnetLocal" }

Write-Host "`n=== CRITICAL MIGRATION CONSIDERATIONS ===" -ForegroundColor Red
Write-Host "VNets using gateway transit: $($criticalPeerings.Count)" -ForegroundColor Yellow
Write-Host "Custom routes requiring attention: $($customRoutes.Count)" -ForegroundColor Yellow

if ($criticalPeerings.Count -gt 0) {
    Write-Host "`nVNets with gateway dependencies:" -ForegroundColor Yellow
    $criticalPeerings | ForEach-Object { Write-Host "  - $($_.VNetName) in $($_.SubscriptionName)" -ForegroundColor White }
}

Write-Host "`n=== VIRTUAL WAN MIGRATION READINESS ===" -ForegroundColor Yellow
Write-Host "Files created for detailed analysis:" -ForegroundColor Cyan
Write-Host "- VNet Peering: VNet-Peering-Analysis-$timestamp.csv" -ForegroundColor White
Write-Host "- NSG Rules: NSG-Analysis-$timestamp.csv" -ForegroundColor White
Write-Host "- Route Tables: Route-Table-Analysis-$timestamp.csv" -ForegroundColor White
Write-Host "- Connectivity: Connectivity-Analysis-$timestamp.csv" -ForegroundColor White
Write-Host "- Network Services: Network-Services-Analysis-$timestamp.csv" -ForegroundColor White
