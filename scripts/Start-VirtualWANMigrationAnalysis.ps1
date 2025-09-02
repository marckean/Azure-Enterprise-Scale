#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

<#
.SYNOPSIS
    Comprehensive Azure Virtual Network inventory and Virtual WAN migration planning tool.

.DESCRIPTION
    This master script orchestrates a complete analysis of your Azure environment to prepare for 
    Virtual WAN migration. It combines workload inventory with network dependency analysis to 
    provide actionable migration recommendations.$PSScriptRoot

.PARAMETER OutputPath
    Path where all analysis files will be saved. Defaults to current directory.

.PARAMETER Region
    Azure region to focus analysis on. Defaults to "Australia East".

.PARAMETER GenerateReport
    Generates a comprehensive migration planning report. Default is $true.

.EXAMPLE
    .\Start-VirtualWANMigrationAnalysis.ps1 -OutputPath "C:\Azure-Migration-Analysis"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\Azure-Migration-Analysis",
    
    [Parameter(Mandatory = $false)]
    [string]$Region = "Australia East",
    
    [Parameter(Mandatory = $false)]
    [bool]$GenerateReport = $true
)

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

# Determine script directory
$ScriptDirectory = if ($PSScriptRoot) { 
    $PSScriptRoot 
} else { 
    Split-Path -Parent $MyInvocation.MyCommand.Path 
}

if (-not $ScriptDirectory) {
    $ScriptDirectory = Get-Location
}

Write-Host "Script directory: $ScriptDirectory" -ForegroundColor Gray

# Step 1: Run VNet and Workload Inventory
Write-Host "`n=== STEP 1: VIRTUAL NETWORK AND WORKLOAD INVENTORY ===" -ForegroundColor Yellow
$scriptPath1 = Join-Path $ScriptDirectory "Get-VNetInventory.ps1"
Write-Host "Looking for: $scriptPath1" -ForegroundColor Gray

if (Test-Path $scriptPath1) {
    Write-Host "Running VNet inventory analysis..." -ForegroundColor Green
    & $scriptPath1 -OutputPath $OutputPath -Region $Region
} else {
    Write-Warning "Get-VNetInventory.ps1 not found at $scriptPath1"
    Write-Host "Running inline VNet inventory analysis..." -ForegroundColor Yellow
    
    # Run the VNet inventory inline since the separate script wasn't found
    & {
        # Include the Get-VNetInventory script content inline
        . (Join-Path $ScriptDirectory "Get-VNetInventory-Inline.ps1") -OutputPath $OutputPath -Region $Region
    }
}

# Step 2: Run Network Dependencies Analysis
Write-Host "`n=== STEP 2: NETWORK DEPENDENCIES ANALYSIS ===" -ForegroundColor Yellow
$scriptPath2 = Join-Path $ScriptDirectory "Get-NetworkDependencies.ps1"
Write-Host "Looking for: $scriptPath2" -ForegroundColor Gray

if (Test-Path $scriptPath2) {
    Write-Host "Running network dependencies analysis..." -ForegroundColor Green
    & $scriptPath2 -OutputPath $OutputPath -Region $Region
} else {
    Write-Warning "Get-NetworkDependencies.ps1 not found at $scriptPath2"
    Write-Host "Running inline network dependencies analysis..." -ForegroundColor Yellow
    
    # Run the network dependencies inline since the separate script wasn't found
    & {
        # Include the Get-NetworkDependencies script content inline
        . (Join-Path $ScriptDirectory "Get-NetworkDependencies-Inline.ps1") -OutputPath $OutputPath -Region $Region
    }
}

# Step 3: Generate Migration Planning Report
if ($GenerateReport) {
    Write-Host "`n=== STEP 3: GENERATING MIGRATION PLANNING REPORT ===" -ForegroundColor Yellow
    
    # Find the most recent CSV files
    $vnetFile = Get-ChildItem -Path $OutputPath -Name "VNet-Inventory-*.csv" | Sort-Object CreationTime -Descending | Select-Object -First 1
    $vmFile = Get-ChildItem -Path $OutputPath -Name "VM-Inventory-*.csv" | Sort-Object CreationTime -Descending | Select-Object -First 1
    $peeringFile = Get-ChildItem -Path $OutputPath -Name "VNet-Peering-Analysis-*.csv" | Sort-Object CreationTime -Descending | Select-Object -First 1
    $connectivityFile = Get-ChildItem -Path $OutputPath -Name "Connectivity-Analysis-*.csv" | Sort-Object CreationTime -Descending | Select-Object -First 1
    
    if ($vnetFile -and $vmFile) {
        $vnets = Import-Csv -Path (Join-Path $OutputPath $vnetFile)
        $vms = Import-Csv -Path (Join-Path $OutputPath $vmFile)
        $peerings = if ($peeringFile) { Import-Csv -Path (Join-Path $OutputPath $peeringFile) } else { @() }
        $connectivity = if ($connectivityFile) { Import-Csv -Path (Join-Path $OutputPath $connectivityFile) } else { @() }
        
        # Generate migration planning report
        $reportContent = @"
# Azure Virtual WAN Migration Planning Report
**Generated:** $(Get-Date)
**Region:** $Region
**Analysis Scope:** All subscriptions in tenant

## Executive Summary

This analysis has identified **$($vnets.Count) virtual networks** across **$(($vnets | Select-Object SubscriptionName -Unique).Count) subscriptions** in the $Region region, containing **$($vms.Count) virtual machines** and supporting various workloads.

### Workload Classification
- **Production VNets:** $(($vnets | Where-Object { $_.WorkloadType -eq 'Production' }).Count)
- **Non-Production VNets:** $(($vnets | Where-Object { $_.WorkloadType -eq 'Non-Production' }).Count)
- **Unknown Classification:** $(($vnets | Where-Object { $_.WorkloadType -eq 'Unknown' }).Count)

### Migration Risk Assessment
- **VNet Peerings:** $($peerings.Count) peering relationships identified
- **Gateway Dependencies:** $(($peerings | Where-Object { $_.UseRemoteGateways -eq 'True' -or $_.AllowGatewayTransit -eq 'True' }).Count) VNets with gateway dependencies
- **Hybrid Connectivity:** $($connectivity.Count) VPN/ExpressRoute gateways

## Recommended Migration Phases

### Phase 1: Non-Production VNets (Pilot)
**Target:** $(($vnets | Where-Object { $_.WorkloadType -eq 'Non-Production' }).Count) VNets
**Risk Level:** Low
**Estimated Duration:** 2-4 weeks

Non-production workloads identified for initial migration:
$(($vnets | Where-Object { $_.WorkloadType -eq 'Non-Production' } | Select-Object -First 10 | ForEach-Object { "- $($_.VNetName) ($($_.SubscriptionName))" }) -join "`n")
$(if (($vnets | Where-Object { $_.WorkloadType -eq 'Non-Production' }).Count -gt 10) { "... and $(($vnets | Where-Object { $_.WorkloadType -eq 'Non-Production' }).Count - 10) more" })

### Phase 2: Unknown Classification Review
**Target:** $(($vnets | Where-Object { $_.WorkloadType -eq 'Unknown' }).Count) VNets
**Risk Level:** Medium
**Action Required:** Manual classification and stakeholder identification

VNets requiring classification:
$(($vnets | Where-Object { $_.WorkloadType -eq 'Unknown' } | Select-Object -First 10 | ForEach-Object { "- $($_.VNetName) ($($_.SubscriptionName))" }) -join "`n")
$(if (($vnets | Where-Object { $_.WorkloadType -eq 'Unknown' }).Count -gt 10) { "... and $(($vnets | Where-Object { $_.WorkloadType -eq 'Unknown' }).Count - 10) more" })

### Phase 3: Production VNets
**Target:** $(($vnets | Where-Object { $_.WorkloadType -eq 'Production' }).Count) VNets
**Risk Level:** High
**Estimated Duration:** 6-12 weeks

Critical production workloads requiring careful planning:
$(($vnets | Where-Object { $_.WorkloadType -eq 'Production' } | Select-Object -First 10 | ForEach-Object { "- $($_.VNetName) ($($_.SubscriptionName))" }) -join "`n")
$(if (($vnets | Where-Object { $_.WorkloadType -eq 'Production' }).Count -gt 10) { "... and $(($vnets | Where-Object { $_.WorkloadType -eq 'Production' }).Count - 10) more" })

## Critical Dependencies and Blockers

### VNet Peering Dependencies
$(if ($peerings.Count -gt 0) {
    $criticalPeerings = $peerings | Where-Object { $_.UseRemoteGateways -eq 'True' -or $_.AllowGatewayTransit -eq 'True' }
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
$(if ($connectivity.Count -gt 0) {
    "**Existing Gateways:** $($connectivity.Count) gateways require migration planning:`n" +
    (($connectivity | ForEach-Object { "- $($_.GatewayName) ($($_.GatewayType)) in $($_.VNetName)" }) -join "`n")
} else {
    "No hybrid connectivity gateways identified."
})

## Application Team Mapping

The following subscriptions and VNets require application team identification:

$(($vnets | Group-Object SubscriptionName | ForEach-Object { 
    "### $($_.Name)`n" +
    (($_.Group | ForEach-Object { "- **$($_.VNetName)** ($($_.WorkloadType)) - $($_.SubnetCount) subnets, $($_.AddressSpace)" }) -join "`n") + "`n"
}) -join "`n")

## Next Steps and Recommendations

1. **Immediate Actions:**
   - Review and validate workload classifications in the Unknown category
   - Identify application owners for each VNet
   - Assess business impact of each workload
   - Document current network routing and connectivity patterns

2. **Phase 1 Preparation (Non-Production):**
   - Create Virtual WAN hub in $Region
   - Establish baseline connectivity tests
   - Prepare rollback procedures
   - Schedule maintenance windows with application teams

3. **Risk Mitigation:**
   - Test connectivity patterns in non-production environment first
   - Implement monitoring and alerting for network connectivity
   - Prepare communication plan for application teams
   - Document all custom routing requirements

4. **Success Criteria:**
   - Zero downtime for production workloads
   - Maintained network performance
   - Successful validation of all connectivity patterns
   - Application team sign-off on connectivity tests

## Files Generated

This analysis has created the following detailed inventory files:
- VNet-Inventory-$timestamp.csv - Complete virtual network inventory
- VM-Inventory-$timestamp.csv - Virtual machine details and locations
- Resource-Inventory-$timestamp.csv - All resources within VNets
- VNet-Peering-Analysis-$timestamp.csv - Network peering relationships
- Connectivity-Analysis-$timestamp.csv - VPN/ExpressRoute gateway analysis
- Summary-Report-$timestamp.csv - High-level statistics

Review these files for detailed planning and coordination with application teams.
"@

        $reportPath = Join-Path $OutputPath "Virtual-WAN-Migration-Plan-$timestamp.md"
        $reportContent | Out-File -FilePath $reportPath -Encoding UTF8
        
        Write-Host "Migration planning report generated: $reportPath" -ForegroundColor Green
    } else {
        Write-Warning "Could not generate report - inventory files not found"
    }
}

Write-Host "`n=== ANALYSIS COMPLETE ===" -ForegroundColor Green
Write-Host "All analysis files have been generated in: $OutputPath" -ForegroundColor Cyan
Write-Host "`nRecommended next steps:" -ForegroundColor Yellow
Write-Host "1. Review the migration planning report for detailed recommendations" -ForegroundColor White
Write-Host "2. Validate workload classifications with application teams" -ForegroundColor White
Write-Host "3. Plan Phase 1 migration for non-production workloads" -ForegroundColor White
Write-Host "4. Coordinate with network and application teams for migration scheduling" -ForegroundColor White

# Open the output directory
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    try {
        Start-Process explorer.exe -ArgumentList $OutputPath
    } catch {
        Write-Host "Output directory: $OutputPath" -ForegroundColor Cyan
    }
}
