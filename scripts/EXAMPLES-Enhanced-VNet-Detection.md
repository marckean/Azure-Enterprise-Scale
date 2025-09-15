# Example Usage - Enhanced VNet Detection

This document provides practical examples of how to use the enhanced VNet detection functionality to resolve the "VNet not found" warnings.

## Quick Start

### 1. Run Enhanced Validation on All Subscriptions

```powershell
# Navigate to the scripts directory
cd /path/to/Azure-Enterprise-Scale/scripts

# Run enhanced validation across all subscriptions
.\Enhanced-VNet-Validation.ps1 -OutputPath "C:\temp\vnet-validation"
```

This will:
- Analyze all VNets with peerings across all accessible subscriptions
- Generate a detailed CSV report with validation status for each peering
- Provide console output showing validation results in real-time

### 2. Target Specific VNet for Validation

```powershell
# Validate a specific VNet that's showing warnings
.\Enhanced-VNet-Validation.ps1 `
    -TargetSubscriptionId "974f38aa-46ab-4729-8374-837427fc24cd" `
    -TargetResourceGroup "Downer_Test" `
    -TargetVNetName "vNet03" `
    -OutputPath "C:\temp\specific-validation"
```

### 3. Run Complete Analysis with Enhanced Validation

```powershell
# Run the complete Virtual WAN analysis with enhanced peering validation
.\Complete-VirtualWANAnalysis.ps1 `
    -OutputPath "C:\temp\complete-analysis" `
    -Region "australiaeast"
```

## Interpreting Results

### Console Output Examples

#### ✅ Successful Validation
```
Analyzing peering: Hub-to-Spoke-Peering
  Validating remote VNet: spoke-vnet-01 in subscription 12345678-1234-1234-1234-123456789012
  ✅ Remote VNet validated successfully
```

#### ⚠️ Access Denied (Expected for Cross-Tenant)
```
Analyzing peering: Cross-Tenant-Peering
  Validating remote VNet: partner-vnet in subscription 87654321-4321-4321-4321-210987654321
  ⚠️ Access denied to remote VNet partner-vnet in subscription 87654321... - this may be expected for cross-tenant or restricted subscriptions
```

#### ❌ VNet Not Found (Potential Stale Link)
```
Analyzing peering: Old-Peering
  Validating remote VNet: deleted-vnet in subscription 11111111-2222-3333-4444-555555555555
  ❌ VNet deleted-vnet not found in subscription 11111111..., resource group old-rg. This may indicate a stale peering link.
```

### CSV Output Columns

The enhanced validation adds these columns to the peering analysis:

| Column | Values | Description |
|--------|--------|-------------|
| `ValidationStatus` | Validated, Access Denied, Not Found, Error | Status of the remote VNet validation |
| `ValidationMessage` | Detailed text | Specific information about the validation result |
| `Timestamp` | yyyy-MM-dd HH:mm:ss | When the validation was performed |

### Example CSV Row
```csv
SourceVNetName,PeeringName,RemoteVNetName,RemoteSubscription,ValidationStatus,ValidationMessage,Timestamp
hub-vnet,hub-to-spoke,spoke-vnet-01,12345...,Validated,Remote VNet exists and is accessible,2024-01-15 10:30:25
hub-vnet,cross-tenant,partner-vnet,87654...,Access Denied,Cannot access subscription 87654...,2024-01-15 10:30:27
hub-vnet,old-link,deleted-vnet,11111...,Not Found,VNet deleted-vnet not found in resource group old-rg,2024-01-15 10:30:29
```

## Troubleshooting Scenarios

### Scenario 1: "VNet not found" but VNet exists

**Problem**: Getting warnings about VNets not found, but you can see them in the Azure portal.

**Solution**:
1. Run the enhanced validation script
2. Check if the result shows "Access Denied"
3. If access denied, verify permissions to the remote subscription
4. If "Not Found", check if the VNet was moved or renamed

```powershell
# Target the specific VNet showing the warning
.\Enhanced-VNet-Validation.ps1 `
    -TargetSubscriptionId "974f38aa-46ab-4729-8374-837427fc24cd" `
    -TargetResourceGroup "Downer_Test" `
    -TargetVNetName "vNet03"
```

### Scenario 2: Cross-subscription peerings show access denied

**Problem**: Peerings to other subscriptions show "Access Denied".

**Root Cause**: This is often expected when:
- Subscriptions are in different Azure AD tenants
- You don't have Reader access to the remote subscription
- The remote subscription is disabled or deleted

**Solution**:
1. Confirm with the remote subscription owner that the VNet exists
2. Request Reader access to the remote subscription if needed
3. Document these peerings separately for migration planning

### Scenario 3: Genuine stale peering links

**Problem**: VNets that truly don't exist anymore.

**Solution**:
1. Enhanced validation will show "Not Found" status
2. Review the peering configuration
3. Remove stale peering links:

```powershell
# Example: Remove stale peering
$vnet = Get-AzVirtualNetwork -ResourceGroupName "myRG" -Name "myVNet"
Remove-AzVirtualNetworkPeering -VirtualNetwork $vnet -Name "stale-peering-name"
```

## Best Practices

### 1. Regular Validation Schedule

Run enhanced validation monthly to catch stale peerings:

```powershell
# Create a scheduled task or Azure Automation runbook
.\Enhanced-VNet-Validation.ps1 -OutputPath "C:\reports\monthly-validation"
```

### 2. Permission Planning

Before running analysis, ensure you have:

```powershell
# Check your current permissions across subscriptions
Get-AzSubscription | ForEach-Object {
    $subName = $_.Name
    $subId = $_.Id
    try {
        Set-AzContext -SubscriptionId $subId | Out-Null
        $vnets = Get-AzVirtualNetwork -ErrorAction SilentlyContinue
        Write-Host "$subName - Can access $($vnets.Count) VNets" -ForegroundColor Green
    }
    catch {
        Write-Host "$subName - Access denied" -ForegroundColor Red
    }
}
```

### 3. Migration Planning Workflow

1. **Run enhanced validation** to identify all peering statuses
2. **Categorize results**:
   - Validated peerings: Include in migration plan
   - Access denied: Coordinate with remote owners
   - Not found: Clean up stale links
3. **Document findings** for migration planning
4. **Re-run validation** after cleanup to confirm changes

### 4. Team Coordination

For enterprise environments:

```powershell
# Generate summary report for team review
.\Enhanced-VNet-Validation.ps1 -OutputPath "\\shared\reports\vnet-validation"

# Email summary to team (example)
$results = Import-Csv "\\shared\reports\vnet-validation\Enhanced-VNet-Peering-Validation-*.csv"
$summary = $results | Group-Object ValidationStatus | 
    Select-Object Name, Count | 
    Format-Table -AutoSize | 
    Out-String

Send-MailMessage -To "network-team@company.com" `
    -Subject "VNet Peering Validation Summary" `
    -Body $summary `
    -SmtpServer "smtp.company.com"
```

## Integration with Existing Scripts

The enhanced validation is backward compatible with existing workflows:

```powershell
# Existing workflow
.\Complete-VirtualWANAnalysis.ps1 -OutputPath "C:\analysis"

# Enhanced workflow (same command, better validation)
.\Complete-VirtualWANAnalysis.ps1 -OutputPath "C:\analysis"
# Now includes enhanced peering validation automatically
```

## Performance Considerations

- **Cross-subscription validation** adds time but provides valuable insights
- **Large environments**: Consider running validation during off-hours
- **Rate limiting**: Azure APIs may throttle with many rapid requests
- **Parallel processing**: Future enhancement could parallelize subscription checks