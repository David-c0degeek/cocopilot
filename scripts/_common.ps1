#Requires -Version 7.4

<#
.SYNOPSIS
    Shared helpers for cocopilot's launcher scripts. Dot-source this, don't
    run it directly. It loads the six helper files below. Their order does
    not matter at run time, because they only define functions.
#>

. (Join-Path $PSScriptRoot "_io.ps1")
. (Join-Path $PSScriptRoot "_mailbox.ps1")
. (Join-Path $PSScriptRoot "_log.ps1")
. (Join-Path $PSScriptRoot "_ownership.ps1")
. (Join-Path $PSScriptRoot "_exclude.ps1")
. (Join-Path $PSScriptRoot "_launch.ps1")
