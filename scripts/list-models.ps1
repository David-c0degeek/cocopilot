#Requires -Version 7.4
<#
.SYNOPSIS
    Lists Copilot models available to the current account and their launch
    settings.

.DESCRIPTION
    Queries the model catalog exposed by the SDK bundled with the installed
    Copilot CLI, including supported reasoning efforts, context tiers/token
    limits, category, and price category.

    If account-aware discovery is unavailable (for example, Node.js is not on
    PATH), falls back to the model IDs advertised by `copilot completion bash`
    and labels the missing availability/capability data as unknown.

.PARAMETER Raw
    Return reusable model descriptor objects instead of a formatted table.

.PARAMETER NoFallback
    Fail if the account-aware SDK query cannot run rather than using the
    installed CLI's advertised model list.
#>
param(
    [switch]$Raw,
    [switch]$NoFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_models.ps1")

$catalog = @(Get-CocopilotModelCatalog -NoFallback:$NoFallback)
if ($Raw) {
    $catalog
    return
}

Show-CocopilotModelCatalog -Catalog $catalog
