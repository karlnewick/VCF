#!/usr/bin/env pwsh
# Wrapper to run the top-level vcf_esxi_preflight.ps1 from the tools folder
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$parentScript = Join-Path $scriptDir '..\vcf_esxi_preflight.ps1'
if (-not (Test-Path $parentScript)) { Write-Host "Parent script not found: $parentScript" -ForegroundColor Red; exit 1 }
& $parentScript @Args
