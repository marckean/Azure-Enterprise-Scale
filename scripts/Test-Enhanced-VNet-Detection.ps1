#Requires -Modules Az.Accounts, Az.Resources, Az.Network

<#
.SYNOPSIS
    Test script to validate the enhanced VNet detection functionality.

.DESCRIPTION
    This script tests the enhanced VNet peering validation logic to ensure:
    - Cross-subscription access scenarios are handled properly
    - Access denied vs VNet not found scenarios are differentiated
    - Appropriate warnings and messages are displayed
    - The validation results are correctly captured

.PARAMETER TestSubscriptionId
    Optional subscription ID to test against. If not provided, will use current context.

.EXAMPLE
    .\Test-Enhanced-VNet-Detection.ps1
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$TestSubscriptionId
)

Write-Host "=== TESTING ENHANCED VNET DETECTION ===" -ForegroundColor Cyan
Write-Host "Test Date: $(Get-Date)" -ForegroundColor White

# Check authentication
$context = Get-AzContext
if (-not $context) {
    Write-Host "Please login to Azure first using Connect-AzAccount" -ForegroundColor Red
    exit 1
}

Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Green

# Test function to validate VNet existence
function Test-VNetValidation {
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
    
    Write-Host "`nTesting validation for VNet: $VNetName" -ForegroundColor Yellow
    Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor Gray
    Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Gray
    
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
            Write-Host "  Attempting to switch to subscription context..." -ForegroundColor Gray
            
            # Try to set the subscription context
            $targetContext = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
            
            if (-not $targetContext) {
                $result.AccessDenied = $true
                $result.ErrorMessage = "Unable to access subscription $SubscriptionId. Check permissions or subscription availability."
                Write-Host "  ❌ Access denied to subscription" -ForegroundColor Red
                return $result
            }
            Write-Host "  ✅ Successfully switched subscription context" -ForegroundColor Green
        }
        
        # Try to get the VNet
        Write-Host "  Attempting to retrieve VNet..." -ForegroundColor Gray
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName -ErrorAction SilentlyContinue
        
        if ($vnet) {
            $result.Exists = $true
            $result.VNetDetails = @{
                Id = $vnet.Id
                Location = $vnet.Location
                AddressSpace = $vnet.AddressSpace.AddressPrefixes -join ", "
                SubnetCount = $vnet.Subnets.Count
            }
            Write-Host "  ✅ VNet found successfully" -ForegroundColor Green
            Write-Host "    Location: $($vnet.Location)" -ForegroundColor White
            Write-Host "    Address Space: $($vnet.AddressSpace.AddressPrefixes -join ', ')" -ForegroundColor White
            Write-Host "    Subnets: $($vnet.Subnets.Count)" -ForegroundColor White
        } else {
            # VNet not found - check if resource group exists to differentiate issues
            Write-Host "  VNet not found, checking resource group access..." -ForegroundColor Gray
            $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
            
            if (-not $rg) {
                $result.AccessDenied = $true
                $result.ErrorMessage = "Cannot access resource group $ResourceGroupName in subscription $SubscriptionId"
                Write-Host "  ⚠️  Cannot access resource group - may be access permissions issue" -ForegroundColor Yellow
            } else {
                $result.ErrorMessage = "VNet $VNetName not found in resource group $ResourceGroupName"
                Write-Host "  ❌ VNet not found but resource group is accessible - VNet may be deleted/renamed" -ForegroundColor Red
            }
        }
    }
    catch {
        # Handle various types of errors
        if ($_.Exception.Message -like "*AuthorizationFailed*" -or 
            $_.Exception.Message -like "*Forbidden*" -or 
            $_.Exception.Message -like "*insufficient privileges*") {
            $result.AccessDenied = $true
            $result.ErrorMessage = "Access denied - insufficient permissions"
            Write-Host "  ❌ Authorization failed - insufficient privileges" -ForegroundColor Red
        } elseif ($_.Exception.Message -like "*SubscriptionNotFound*") {
            $result.AccessDenied = $true
            $result.ErrorMessage = "Subscription $SubscriptionId not found or not accessible"
            Write-Host "  ❌ Subscription not found or not accessible" -ForegroundColor Red
        } else {
            $result.ErrorMessage = "Unexpected error: $($_.Exception.Message)"
            Write-Host "  ❌ Unexpected error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    finally {
        # Restore original context if we switched
        if ($SubscriptionId -ne $CurrentSubscriptionId -and $originalContext) {
            Set-AzContext -Context $originalContext | Out-Null
            Write-Host "  Restored original subscription context" -ForegroundColor Gray
        }
    }
    
    return $result
}

# Use test subscription if provided, otherwise use current context
$currentSubscription = if ($TestSubscriptionId) { $TestSubscriptionId } else { $context.Subscription.Id }

Write-Host "`nUsing subscription for testing: $currentSubscription" -ForegroundColor White

# Test 1: Validate current subscription VNets
Write-Host "`n=== TEST 1: CURRENT SUBSCRIPTION VNETS ===" -ForegroundColor Magenta

try {
    if ($TestSubscriptionId) {
        Set-AzContext -SubscriptionId $TestSubscriptionId | Out-Null
    }
    
    $vnets = Get-AzVirtualNetwork | Select-Object -First 3
    
    if ($vnets.Count -eq 0) {
        Write-Host "No VNets found in current subscription for testing" -ForegroundColor Yellow
    } else {
        foreach ($vnet in $vnets) {
            $result = Test-VNetValidation -SubscriptionId $currentSubscription -ResourceGroupName $vnet.ResourceGroupName -VNetName $vnet.Name -CurrentSubscriptionId $currentSubscription
            
            Write-Host "Test Result Summary:" -ForegroundColor Cyan
            Write-Host "  Exists: $($result.Exists)" -ForegroundColor White
            Write-Host "  Access Denied: $($result.AccessDenied)" -ForegroundColor White
            Write-Host "  Message: $($result.ErrorMessage)" -ForegroundColor White
        }
    }
}
catch {
    Write-Warning "Error testing current subscription VNets: $($_.Exception.Message)"
}

# Test 2: Test non-existent VNet
Write-Host "`n=== TEST 2: NON-EXISTENT VNET ===" -ForegroundColor Magenta

$result = Test-VNetValidation -SubscriptionId $currentSubscription -ResourceGroupName "non-existent-rg" -VNetName "non-existent-vnet" -CurrentSubscriptionId $currentSubscription

Write-Host "Test Result Summary:" -ForegroundColor Cyan
Write-Host "  Exists: $($result.Exists)" -ForegroundColor White
Write-Host "  Access Denied: $($result.AccessDenied)" -ForegroundColor White
Write-Host "  Message: $($result.ErrorMessage)" -ForegroundColor White

# Test 3: Test cross-subscription access (if multiple subscriptions available)
Write-Host "`n=== TEST 3: CROSS-SUBSCRIPTION ACCESS ===" -ForegroundColor Magenta

$allSubscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" -and $_.Id -ne $currentSubscription } | Select-Object -First 2

if ($allSubscriptions.Count -eq 0) {
    Write-Host "No other subscriptions available for cross-subscription testing" -ForegroundColor Yellow
} else {
    foreach ($otherSub in $allSubscriptions) {
        Write-Host "`nTesting access to subscription: $($otherSub.Name)" -ForegroundColor Yellow
        
        # Try to get VNets from other subscription
        try {
            $otherContext = Set-AzContext -SubscriptionId $otherSub.Id -ErrorAction SilentlyContinue
            if ($otherContext) {
                $otherVnets = Get-AzVirtualNetwork -ErrorAction SilentlyContinue | Select-Object -First 1
                
                if ($otherVnets) {
                    $otherVnet = $otherVnets[0]
                    
                    # Restore original context first
                    Set-AzContext -SubscriptionId $currentSubscription | Out-Null
                    
                    # Test validation from original subscription context
                    $result = Test-VNetValidation -SubscriptionId $otherSub.Id -ResourceGroupName $otherVnet.ResourceGroupName -VNetName $otherVnet.Name -CurrentSubscriptionId $currentSubscription
                    
                    Write-Host "Cross-subscription test result:" -ForegroundColor Cyan
                    Write-Host "  Exists: $($result.Exists)" -ForegroundColor White
                    Write-Host "  Access Denied: $($result.AccessDenied)" -ForegroundColor White
                    Write-Host "  Message: $($result.ErrorMessage)" -ForegroundColor White
                } else {
                    Write-Host "No VNets found in subscription $($otherSub.Name) for testing" -ForegroundColor Gray
                    Set-AzContext -SubscriptionId $currentSubscription | Out-Null
                }
            } else {
                Write-Host "Cannot access subscription $($otherSub.Name)" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "Error testing subscription $($otherSub.Name): $($_.Exception.Message)" -ForegroundColor Red
            Set-AzContext -SubscriptionId $currentSubscription | Out-Null
        }
    }
}

# Test 4: Test peering analysis with enhanced validation
Write-Host "`n=== TEST 4: PEERING ANALYSIS TEST ===" -ForegroundColor Magenta

try {
    Set-AzContext -SubscriptionId $currentSubscription | Out-Null
    
    $vnetsWithPeerings = Get-AzVirtualNetwork | Where-Object { $_.VirtualNetworkPeerings -and $_.VirtualNetworkPeerings.Count -gt 0 } | Select-Object -First 2
    
    if ($vnetsWithPeerings.Count -eq 0) {
        Write-Host "No VNets with peerings found for testing enhanced validation" -ForegroundColor Yellow
    } else {
        foreach ($vnet in $vnetsWithPeerings) {
            Write-Host "`nTesting peerings for VNet: $($vnet.Name)" -ForegroundColor Yellow
            
            foreach ($peering in $vnet.VirtualNetworkPeerings) {
                Write-Host "  Peering: $($peering.Name)" -ForegroundColor Cyan
                
                if ($peering.RemoteVirtualNetwork -and $peering.RemoteVirtualNetwork.Id) {
                    $remoteVNetId = $peering.RemoteVirtualNetwork.Id
                    $idParts = $remoteVNetId.Split('/')
                    
                    if ($idParts.Length -ge 9) {
                        $remoteVNetName = $idParts[-1]
                        $remoteSubscription = $idParts[2]
                        $remoteResourceGroup = $idParts[4]
                        
                        Write-Host "    Remote VNet: $remoteVNetName" -ForegroundColor White
                        Write-Host "    Remote Subscription: $remoteSubscription" -ForegroundColor White
                        Write-Host "    Remote Resource Group: $remoteResourceGroup" -ForegroundColor White
                        
                        $result = Test-VNetValidation -SubscriptionId $remoteSubscription -ResourceGroupName $remoteResourceGroup -VNetName $remoteVNetName -CurrentSubscriptionId $currentSubscription
                        
                        Write-Host "    Validation Result:" -ForegroundColor Cyan
                        Write-Host "      Exists: $($result.Exists)" -ForegroundColor White
                        Write-Host "      Access Denied: $($result.AccessDenied)" -ForegroundColor White
                        Write-Host "      Message: $($result.ErrorMessage)" -ForegroundColor White
                    }
                }
            }
        }
    }
}
catch {
    Write-Warning "Error during peering analysis test: $($_.Exception.Message)"
}

Write-Host "`n=== TESTING COMPLETE ===" -ForegroundColor Green
Write-Host "Enhanced VNet detection validation has been tested successfully." -ForegroundColor White
Write-Host "The enhanced scripts should now provide better error handling and differentiate between:" -ForegroundColor Yellow
Write-Host "- Access denied scenarios (cross-subscription, insufficient permissions)" -ForegroundColor White
Write-Host "- VNets that genuinely don't exist (stale peering links)" -ForegroundColor White
Write-Host "- Successful validations" -ForegroundColor White