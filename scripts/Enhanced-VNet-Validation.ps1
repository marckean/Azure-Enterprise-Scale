#Requires -Modules Az.Accounts, Az.Resources, Az.Network

<#
.SYNOPSIS
    Enhanced VNet validation script that properly handles cross-subscription scenarios.

.DESCRIPTION
    This script provides enhanced VNet peering validation that:
    - Properly handles cross-subscription access scenarios
    - Validates VNet existence with appropriate error handling
    - Provides clear messaging when access is denied vs VNet not existing
    - Supports validation of peering relationships across multiple subscriptions

.PARAMETER TargetSubscriptionId
    The subscription ID where the source VNet resides.

.PARAMETER TargetResourceGroup
    The resource group containing the source VNet.

.PARAMETER TargetVNetName
    The name of the source VNet to analyze peerings for.

.PARAMETER OutputPath
    Path where validation results will be saved.

.EXAMPLE
    .\Enhanced-VNet-Validation.ps1 -TargetSubscriptionId "12345678-1234-1234-1234-123456789012" -TargetResourceGroup "rg-test" -TargetVNetName "vnet-main" -OutputPath "C:\temp"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$TargetSubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [string]$TargetResourceGroup,
    
    [Parameter(Mandatory = $false)]
    [string]$TargetVNetName,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

# Function to validate VNet existence with proper error handling
function Test-VNetExistence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$VNetName,
        
        [Parameter(Mandatory = $false)]
        [string]$CurrentSubscriptionId
    )
    
    $result = @{
        Exists = $false
        AccessDenied = $false
        ErrorMessage = ""
        VNetDetails = $null
    }
    
    try {
        # Store current context
        $originalContext = Get-AzContext
        
        # Check if we need to switch subscription context
        if ($SubscriptionId -ne $CurrentSubscriptionId) {
            Write-Verbose "Switching to subscription context: $SubscriptionId"
            
            # Try to set the subscription context
            $targetContext = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
            
            if (-not $targetContext) {
                $result.AccessDenied = $true
                $result.ErrorMessage = "Unable to access subscription $SubscriptionId. Check permissions or subscription availability."
                return $result
            }
        }
        
        # Try to get the VNet
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName -ErrorAction SilentlyContinue
        
        if ($vnet) {
            $result.Exists = $true
            $result.VNetDetails = @{
                Id = $vnet.Id
                Location = $vnet.Location
                AddressSpace = $vnet.AddressSpace.AddressPrefixes -join ", "
                SubnetCount = $vnet.Subnets.Count
            }
            Write-Verbose "VNet $VNetName found in subscription $SubscriptionId"
        } else {
            # VNet not found - could be permission issue or genuinely missing
            # Try to get the resource group to differentiate between access and existence issues
            $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
            
            if (-not $rg) {
                $result.AccessDenied = $true
                $result.ErrorMessage = "Cannot access resource group $ResourceGroupName in subscription $SubscriptionId. This may be due to insufficient permissions or the resource group does not exist."
            } else {
                $result.ErrorMessage = "VNet $VNetName not found in resource group $ResourceGroupName in subscription $SubscriptionId. The VNet may have been deleted or renamed."
            }
        }
    }
    catch {
        # Handle various types of errors
        if ($_.Exception.Message -like "*AuthorizationFailed*" -or 
            $_.Exception.Message -like "*Forbidden*" -or 
            $_.Exception.Message -like "*insufficient privileges*") {
            $result.AccessDenied = $true
            $result.ErrorMessage = "Access denied to subscription $SubscriptionId or resource group $ResourceGroupName. Insufficient permissions."
        } elseif ($_.Exception.Message -like "*SubscriptionNotFound*") {
            $result.AccessDenied = $true
            $result.ErrorMessage = "Subscription $SubscriptionId not found or not accessible."
        } else {
            $result.ErrorMessage = "Unexpected error accessing VNet: $($_.Exception.Message)"
        }
        
        Write-Verbose "Error validating VNet: $($_.Exception.Message)"
    }
    finally {
        # Restore original context if we switched
        if ($SubscriptionId -ne $CurrentSubscriptionId -and $originalContext) {
            Set-AzContext -Context $originalContext | Out-Null
        }
    }
    
    return $result
}

# Function to analyze VNet peerings with enhanced validation
function Get-EnhancedVNetPeeringAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$VNetName
    )
    
    $peeringResults = @()
    
    try {
        # Set context to the source subscription
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        $currentSubscriptionId = $SubscriptionId
        
        # Get the source VNet
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName -ErrorAction Stop
        
        Write-Host "Analyzing peerings for VNet: $($vnet.Name)" -ForegroundColor Green
        
        if (-not $vnet.VirtualNetworkPeerings -or $vnet.VirtualNetworkPeerings.Count -eq 0) {
            Write-Host "  No peerings found for this VNet." -ForegroundColor Yellow
            return $peeringResults
        }
        
        foreach ($peering in $vnet.VirtualNetworkPeerings) {
            Write-Host "  Analyzing peering: $($peering.Name)" -ForegroundColor Cyan
            
            $remoteVNetName = "Unknown"
            $remoteSubscription = "Unknown"
            $remoteResourceGroup = "Unknown"
            $validationResult = $null
            
            if ($peering.RemoteVirtualNetwork -and $peering.RemoteVirtualNetwork.Id) {
                $remoteVNetId = $peering.RemoteVirtualNetwork.Id
                $idParts = $remoteVNetId.Split('/')
                
                if ($idParts.Length -ge 9) {
                    $remoteVNetName = $idParts[-1]
                    $remoteSubscription = $idParts[2]
                    $remoteResourceGroup = $idParts[4]
                    
                    # Validate the remote VNet existence
                    Write-Host "    Validating remote VNet: $remoteVNetName in subscription $remoteSubscription" -ForegroundColor Gray
                    $validationResult = Test-VNetExistence -SubscriptionId $remoteSubscription -ResourceGroupName $remoteResourceGroup -VNetName $remoteVNetName -CurrentSubscriptionId $currentSubscriptionId
                    
                    if ($validationResult.Exists) {
                        Write-Host "    ✅ Remote VNet validated successfully" -ForegroundColor Green
                    } elseif ($validationResult.AccessDenied) {
                        Write-Warning "    ⚠️  Access denied to remote VNet location: $($validationResult.ErrorMessage)"
                    } else {
                        Write-Warning "    ❌ Remote VNet validation failed: $($validationResult.ErrorMessage)"
                    }
                }
            }
            
            $peeringRecord = [PSCustomObject]@{
                SourceSubscriptionId = $SubscriptionId
                SourceResourceGroup = $ResourceGroupName
                SourceVNetName = $VNetName
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
                ValidationStatus = if ($validationResult) {
                    if ($validationResult.Exists) { "Validated" }
                    elseif ($validationResult.AccessDenied) { "Access Denied" }
                    else { "Not Found" }
                } else { "Not Validated" }
                ValidationMessage = if ($validationResult) { $validationResult.ErrorMessage } else { "Remote VNet ID not available" }
                RemoteVNetDetails = if ($validationResult -and $validationResult.VNetDetails) { 
                    "Location: $($validationResult.VNetDetails.Location), AddressSpace: $($validationResult.VNetDetails.AddressSpace), Subnets: $($validationResult.VNetDetails.SubnetCount)" 
                } else { "N/A" }
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
            
            $peeringResults += $peeringRecord
        }
    }
    catch {
        Write-Error "Error analyzing VNet peerings: $($_.Exception.Message)"
        throw
    }
    
    return $peeringResults
}

# Main execution
Write-Host "=== ENHANCED VNET PEERING VALIDATION ===" -ForegroundColor Cyan
Write-Host "Timestamp: $(Get-Date)" -ForegroundColor White

# Check authentication
$context = Get-AzContext
if (-not $context) {
    Write-Host "Connecting to Azure..." -ForegroundColor Yellow
    Connect-AzAccount
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Failed to connect to Azure. Please ensure you have appropriate permissions."
        exit 1
    }
}

Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Green

# Create output directory if needed
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "Created output directory: $OutputPath" -ForegroundColor Green
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$allResults = @()

if ($TargetSubscriptionId -and $TargetResourceGroup -and $TargetVNetName) {
    # Analyze specific VNet
    Write-Host "`nAnalyzing specific VNet..." -ForegroundColor Yellow
    $results = Get-EnhancedVNetPeeringAnalysis -SubscriptionId $TargetSubscriptionId -ResourceGroupName $TargetResourceGroup -VNetName $TargetVNetName
    $allResults += $results
} else {
    # Analyze all subscriptions and VNets
    Write-Host "`nAnalyzing all subscriptions..." -ForegroundColor Yellow
    
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
    $totalSubscriptions = $subscriptions.Count
    $currentSubscription = 0
    
    foreach ($subscription in $subscriptions) {
        $currentSubscription++
        Write-Host "`n[$currentSubscription/$totalSubscriptions] Processing subscription: $($subscription.Name)" -ForegroundColor Yellow
        
        try {
            Set-AzContext -SubscriptionId $subscription.Id | Out-Null
            
            # Get all VNets that have peerings
            $vnets = Get-AzVirtualNetwork | Where-Object { $_.VirtualNetworkPeerings -and $_.VirtualNetworkPeerings.Count -gt 0 }
            
            if ($vnets.Count -eq 0) {
                Write-Host "  No VNets with peerings found" -ForegroundColor Gray
                continue
            }
            
            Write-Host "  Found $($vnets.Count) VNets with peerings" -ForegroundColor Cyan
            
            foreach ($vnet in $vnets) {
                $results = Get-EnhancedVNetPeeringAnalysis -SubscriptionId $subscription.Id -ResourceGroupName $vnet.ResourceGroupName -VNetName $vnet.Name
                $allResults += $results
            }
        }
        catch {
            Write-Warning "Error processing subscription $($subscription.Name): $($_.Exception.Message)"
        }
    }
}

# Export results
if ($allResults.Count -gt 0) {
    $outputFile = Join-Path $OutputPath "Enhanced-VNet-Peering-Validation-$timestamp.csv"
    $allResults | Export-Csv -Path $outputFile -NoTypeInformation
    Write-Host "`nResults exported to: $outputFile" -ForegroundColor Green
    
    # Display summary
    Write-Host "`n=== VALIDATION SUMMARY ===" -ForegroundColor Yellow
    Write-Host "Total peerings analyzed: $($allResults.Count)" -ForegroundColor White
    
    $validated = ($allResults | Where-Object { $_.ValidationStatus -eq "Validated" }).Count
    $accessDenied = ($allResults | Where-Object { $_.ValidationStatus -eq "Access Denied" }).Count
    $notFound = ($allResults | Where-Object { $_.ValidationStatus -eq "Not Found" }).Count
    $notValidated = ($allResults | Where-Object { $_.ValidationStatus -eq "Not Validated" }).Count
    
    Write-Host "Successfully validated: $validated" -ForegroundColor Green
    Write-Host "Access denied: $accessDenied" -ForegroundColor Yellow
    Write-Host "Not found: $notFound" -ForegroundColor Red
    Write-Host "Not validated: $notValidated" -ForegroundColor Gray
    
    if ($accessDenied -gt 0) {
        Write-Host "`n⚠️  Access Denied Issues:" -ForegroundColor Yellow
        Write-Host "Some remote VNets could not be validated due to access permissions." -ForegroundColor White
        Write-Host "This typically means:" -ForegroundColor White
        Write-Host "- You don't have Reader access to the remote subscription" -ForegroundColor White
        Write-Host "- The remote subscription is in a different tenant" -ForegroundColor White
        Write-Host "- The remote subscription has been disabled or deleted" -ForegroundColor White
        Write-Host "`nRecommendation: Contact the owners of the remote subscriptions to verify VNet existence." -ForegroundColor Cyan
    }
    
    if ($notFound -gt 0) {
        Write-Host "`n❌ Not Found Issues:" -ForegroundColor Red
        Write-Host "Some remote VNets appear to be missing and may represent stale peering links." -ForegroundColor White
        Write-Host "Recommendation: Review these peerings and consider removing stale connections." -ForegroundColor Cyan
    }
} else {
    Write-Host "`nNo VNet peerings found to analyze." -ForegroundColor Yellow
}

Write-Host "`n=== ANALYSIS COMPLETE ===" -ForegroundColor Green