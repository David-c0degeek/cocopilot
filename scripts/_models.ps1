#Requires -Version 7.4
<#
.SYNOPSIS
    Internal model discovery and launch-configuration helpers.

.DESCRIPTION
    The preferred path queries the current user's model catalog through the
    SDK bundled with the installed Copilot CLI. If that optional discovery
    path is unavailable, callers may fall back to the model IDs advertised by
    `copilot completion bash`; those IDs are not account/policy filtered and
    do not include per-model capabilities.
#>

function Get-CocopilotObjectProperty {
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return }
    return $property.Value
}

function Get-CocopilotNestedProperty {
    param(
        $InputObject,
        [Parameter(Mandatory)][string[]]$Path
    )

    $value = $InputObject
    foreach ($segment in $Path) {
        $value = Get-CocopilotObjectProperty -InputObject $value -Name $segment
        if ($null -eq $value) { return }
    }
    return $value
}

function ConvertTo-CocopilotModelDescriptor {
    param(
        [Parameter(Mandatory)]$Model,
        [ValidateSet("account", "cli-completion")][string]$Source = "account"
    )

    $id = [string](Get-CocopilotObjectProperty -InputObject $Model -Name "id")
    if ([string]::IsNullOrWhiteSpace($id)) {
        throw "Copilot returned a model without an id."
    }

    $name = [string](Get-CocopilotObjectProperty -InputObject $Model -Name "name")
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }

    $efforts = @(Get-CocopilotObjectProperty -InputObject $Model -Name "supportedReasoningEfforts")
    if ($efforts.Count -eq 0) {
        $efforts = @(Get-CocopilotNestedProperty -InputObject $Model -Path @("capabilities", "supports", "reasoning_effort"))
    }
    $efforts = @($efforts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })

    $defaultEffort = [string](Get-CocopilotObjectProperty -InputObject $Model -Name "defaultReasoningEffort")
    if ([string]::IsNullOrWhiteSpace($defaultEffort)) { $defaultEffort = $null }

    $standardContextTokens = Get-CocopilotNestedProperty -InputObject $Model -Path @("billing", "tokenPrices", "maxPromptTokens")
    if ($null -eq $standardContextTokens) {
        $standardContextTokens = Get-CocopilotNestedProperty -InputObject $Model -Path @("billing", "tokenPrices", "contextMax")
    }
    $longContextMetadata = Get-CocopilotNestedProperty -InputObject $Model -Path @("billing", "tokenPrices", "longContext")
    $longContextTokens = Get-CocopilotNestedProperty -InputObject $longContextMetadata -Path @("maxPromptTokens")
    if ($null -eq $longContextTokens) {
        $longContextTokens = Get-CocopilotNestedProperty -InputObject $longContextMetadata -Path @("contextMax")
    }
    $maxPromptTokens = Get-CocopilotNestedProperty -InputObject $Model -Path @("capabilities", "limits", "max_prompt_tokens")
    $maxContextTokens = Get-CocopilotNestedProperty -InputObject $Model -Path @("capabilities", "limits", "max_context_window_tokens")
    $maxOutputTokens = Get-CocopilotNestedProperty -InputObject $Model -Path @("capabilities", "limits", "max_output_tokens")

    if ($null -eq $standardContextTokens) {
        $standardContextTokens = if ($null -ne $maxPromptTokens) { $maxPromptTokens } else { $maxContextTokens }
    }

    $hasCapabilityMetadata = $Source -eq "account"
    $contextTiers = $null
    if ($hasCapabilityMetadata -and $id -ne "auto") {
        $contextTiers = if ($null -ne $longContextMetadata) {
            [string[]]@("default", "long_context")
        } else {
            [string[]]@("default")
        }
    }

    $policyState = [string](Get-CocopilotNestedProperty -InputObject $Model -Path @("policy", "state"))
    if ([string]::IsNullOrWhiteSpace($policyState)) { $policyState = "unconfigured" }

    return [pscustomobject][ordered]@{
        Id                    = $id
        Name                  = $name
        Category              = [string](Get-CocopilotObjectProperty -InputObject $Model -Name "modelPickerCategory")
        PriceCategory         = [string](Get-CocopilotObjectProperty -InputObject $Model -Name "modelPickerPriceCategory")
        PolicyState           = $policyState
        SupportedEfforts      = if ($hasCapabilityMetadata) { [string[]]$efforts } else { $null }
        DefaultEffort         = $defaultEffort
        ContextTiers          = $contextTiers
        StandardContextTokens = if ($null -ne $standardContextTokens) { [long]$standardContextTokens } else { $null }
        LongContextTokens     = if ($null -ne $longContextTokens) { [long]$longContextTokens } else { $null }
        MaxOutputTokens       = if ($null -ne $maxOutputTokens) { [long]$maxOutputTokens } else { $null }
        HasCapabilityMetadata = $hasCapabilityMetadata
        Source                = $Source
    }
}

function Resolve-CocopilotCommand {
    <#
    .SYNOPSIS
        Returns the full path of the stock `copilot` CLI: the first native
        executable or PowerShell script named copilot on PATH, in the order
        PowerShell itself would run them.

    .DESCRIPTION
        A same-name alias or function from a profile never matches. Only a
        native executable (.exe, .com) or a PowerShell script can carry the
        multi-line agent prompt intact: a cmd.exe shim (.cmd, .bat) gets
        Legacy argument passing and ends the command line at the prompt's
        first line break, and npm's extensionless sh shim cannot be started
        at all. A skipped cmd shim is reported as a warning. A missing CLI
        throws instead of returning a bare `copilot`, which such a function
        could still capture.
    #>
    $skippedShims = [System.Collections.Generic.List[string]]::new()
    foreach ($command in @(Get-Command copilot -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)) {
        $extension = [System.IO.Path]::GetExtension($command.Source)
        if ($command.CommandType -eq "ExternalScript" -or $extension -in @(".exe", ".com")) {
            if ($skippedShims.Count -gt 0) {
                Write-Warning "Skipping $($skippedShims -join ', '): a cmd.exe shim cannot pass the multi-line agent prompt intact. Using '$($command.Source)'."
            }
            return [string]$command.Source
        }
        if ($extension -in @(".cmd", ".bat")) { $skippedShims.Add([string]$command.Source) }
    }

    $shimNote = if ($skippedShims.Count -gt 0) {
        " Found only $($skippedShims -join ', '), which cannot pass the multi-line agent prompt intact."
    } else { "" }
    throw "The GitHub Copilot CLI ('copilot') was not found on PATH as a native executable or PowerShell script.$shimNote Install it or add it to PATH; a same-name alias or function is never used."
}

function Get-CocopilotCliVersion {
    param([string]$CopilotCommand = "copilot")

    $output = & $CopilotCommand --version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the Copilot CLI version: $($output.Trim())"
    }

    $match = [regex]::Match($output, "(?im)\bCopilot CLI\s+(?<version>\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)")
    if (-not $match.Success) {
        throw "Could not parse the Copilot CLI version from: $($output.Trim())"
    }
    return $match.Groups["version"].Value
}

function Get-CocopilotExecutablePath {
    param([string]$CopilotCommand = "copilot")

    $command = Get-Command $CopilotCommand -ErrorAction Stop
    $path = [string]$command.Source
    if ($path -and [System.IO.Path]::GetExtension($path) -ieq ".exe") {
        return $path
    }

    $application = Get-Command "$CopilotCommand.exe" -CommandType Application -ErrorAction SilentlyContinue
    if ($application) { return [string]$application.Source }

    $npmExecutable = Find-CocopilotNpmExecutable -ShimPath $path
    if ($npmExecutable) { return $npmExecutable }

    throw "'$CopilotCommand' does not resolve to an executable that the Copilot SDK can start."
}

function Find-CocopilotNpmExecutable {
    param(
        [Parameter(Mandatory)][string]$ShimPath,
        [ValidateSet("x64", "arm64")][string]$Architecture
    )

    if (-not $Architecture) {
        $processorArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
            $env:PROCESSOR_ARCHITEW6432
        } else {
            $env:PROCESSOR_ARCHITECTURE
        }
        $Architecture = if ($processorArchitecture -eq "ARM64") { "arm64" } else { "x64" }
    }

    $shimDirectory = Split-Path -Parent $ShimPath
    if (-not $shimDirectory) { return }

    $packageName = "copilot-win32-$Architecture"
    $candidates = @(
        (Join-Path $shimDirectory "node_modules\@github\$packageName\copilot.exe"),
        (Join-Path $shimDirectory "node_modules\@github\copilot\node_modules\@github\$packageName\copilot.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return
}

function Find-CocopilotSdkPath {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$CopilotExecutable
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    $directory = Split-Path -Parent $CopilotExecutable
    $scopeDirectory = Split-Path -Parent $directory
    if ((Split-Path -Leaf $scopeDirectory) -eq "@github") {
        $candidates.Add((Join-Path $scopeDirectory "copilot\copilot-sdk\index.js"))
    }
    for ($depth = 0; $depth -lt 6 -and $directory; $depth++) {
        $candidates.Add((Join-Path $directory "copilot-sdk\index.js"))
        $candidates.Add((Join-Path $directory "node_modules\@github\copilot\copilot-sdk\index.js"))
        $parent = Split-Path -Parent $directory
        if ($parent -eq $directory) { break }
        $directory = $parent
    }

    if ($env:LOCALAPPDATA) {
        $packagePattern = Join-Path $env:LOCALAPPDATA "copilot\pkg\*\$Version\copilot-sdk\index.js"
        foreach ($match in @(Get-ChildItem -Path $packagePattern -File -ErrorAction SilentlyContinue)) {
            $candidates.Add($match.FullName)
        }
    }

    if ($env:APPDATA) {
        $candidates.Add((Join-Path $env:APPDATA "npm\node_modules\@github\copilot\copilot-sdk\index.js"))
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return
}

function ConvertFrom-CocopilotModelJson {
    param([Parameter(Mandatory)][string]$Json)

    # Assign first, then foreach, so a top-level JSON array always emits one
    # model object per item.
    $parsedModels = $Json | ConvertFrom-Json
    foreach ($model in $parsedModels) { $model }
}

function Invoke-CocopilotSdkModelQuery {
    param([string]$CopilotCommand = "copilot")

    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
    if (-not $node) {
        throw "Node.js is not on PATH, so the bundled Copilot SDK cannot be queried."
    }

    $version = Get-CocopilotCliVersion -CopilotCommand $CopilotCommand
    $copilotExecutable = Get-CocopilotExecutablePath -CopilotCommand $CopilotCommand
    $sdkPath = Find-CocopilotSdkPath -Version $version -CopilotExecutable $copilotExecutable
    if (-not $sdkPath) {
        throw "Could not find the Copilot SDK bundled with CLI $version."
    }

    $sdkUri = ([Uri](Resolve-Path -LiteralPath $sdkPath).Path).AbsoluteUri
    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("cocopilot-models-" + [Guid]::NewGuid().ToString("N"))
    $scriptPath = "$tempBase.mjs"
    $stdoutPath = "$tempBase.stdout"
    $stderrPath = "$tempBase.stderr"
    $nodeScript = @'
const [sdkUrl, cliPath] = process.argv.slice(2);
const { CopilotClient, RuntimeConnection } = await import(sdkUrl);
const client = new CopilotClient({
  connection: RuntimeConnection.forStdio({ path: cliPath }),
  logLevel: "error"
});

try {
  await client.start();
  process.stdout.write(JSON.stringify(await client.listModels()));
} finally {
  await client.stop();
}
'@

    try {
        [System.IO.File]::WriteAllText($scriptPath, $nodeScript, [System.Text.UTF8Encoding]::new($false))
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $node.Source $scriptPath $sdkUri $copilotExecutable 1> $stdoutPath 2> $stderrPath
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { "" }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
        if ($exitCode -ne 0) {
            throw "Copilot SDK model query failed (exit $exitCode): $($stderr.Trim())"
        }
        if ([string]::IsNullOrWhiteSpace($stdout)) {
            throw "Copilot SDK model query returned no data. $($stderr.Trim())"
        }

        $models = @(ConvertFrom-CocopilotModelJson -Json $stdout)
        $descriptors = foreach ($model in $models) {
            $descriptor = ConvertTo-CocopilotModelDescriptor -Model $model -Source account
            if ($descriptor.PolicyState -ne "disabled") { $descriptor }
        }
        if (@($descriptors).Count -eq 0) {
            throw "Copilot SDK model query returned no enabled models."
        }
        return @($descriptors)
    } finally {
        foreach ($path in @($scriptPath, $stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function ConvertFrom-CocopilotCompletionModels {
    param([Parameter(Mandatory)][string]$CompletionText)

    $match = [regex]::Match(
        $CompletionText,
        "(?s)--model\)\s+.*?compgen\s+-W\s+'(?<models>[^']+)'"
    )
    if (-not $match.Success) {
        throw "Could not find the --model choices in Copilot's bash completion output."
    }

    return @(
        $match.Groups["models"].Value -split "\s+" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

function Get-CocopilotAdvertisedModelCatalog {
    param([string]$CopilotCommand = "copilot")

    $completion = & $CopilotCommand completion bash 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read Copilot's advertised model choices: $($completion.Trim())"
    }

    return @(
        ConvertFrom-CocopilotCompletionModels -CompletionText $completion |
            ForEach-Object {
                ConvertTo-CocopilotModelDescriptor -Model ([pscustomobject]@{ id = $_; name = $_ }) -Source cli-completion
            }
    )
}

function Get-CocopilotModelCatalog {
    param(
        [Parameter(Mandatory)][string]$CopilotCommand,
        [switch]$NoFallback
    )

    try {
        return @(Invoke-CocopilotSdkModelQuery -CopilotCommand $CopilotCommand)
    } catch {
        if ($NoFallback) { throw }
        $warning = ("Could not query the account-specific Copilot model catalog: {0} " +
            "Falling back to models advertised by the installed CLI; availability and per-model settings cannot be verified.") -f $_.Exception.Message
        Write-Warning $warning
        return @(Get-CocopilotAdvertisedModelCatalog -CopilotCommand $CopilotCommand)
    }
}

function Format-CocopilotTokenCount {
    param($Value)

    if ($null -eq $Value) { return "unknown" }
    $number = [double]$Value
    if ($number -ge 1000000) { return ("{0:0.##}M" -f ($number / 1000000)) }
    if ($number -ge 1000) { return ("{0:0.#}K" -f ($number / 1000)) }
    return [string]$Value
}

function Get-CocopilotModelDisplayRows {
    param([Parameter(Mandatory)][object[]]$Catalog)

    $number = 0
    foreach ($model in $Catalog) {
        $number++
        $effort = if (-not $model.HasCapabilityMetadata) {
            "unknown"
        } elseif (@($model.SupportedEfforts).Count -eq 0) {
            "not supported"
        } else {
            @($model.SupportedEfforts) -join ", "
        }

        $context = if (-not $model.HasCapabilityMetadata) {
            "unknown"
        } elseif ($model.Id -eq "auto") {
            "chosen by router"
        } elseif ("long_context" -in @($model.ContextTiers)) {
            "default $(Format-CocopilotTokenCount $model.StandardContextTokens); long_context $(Format-CocopilotTokenCount $model.LongContextTokens)"
        } else {
            "default $(Format-CocopilotTokenCount $model.StandardContextTokens)"
        }

        [pscustomobject][ordered]@{
            Number   = $number
            Model    = $model.Id
            Effort   = $effort
            Context  = $context
            Output   = Format-CocopilotTokenCount $model.MaxOutputTokens
            Category = if ($model.Category) { $model.Category } else { "unknown" }
            Price    = if ($model.PriceCategory) { $model.PriceCategory } else { "unknown" }
        }
    }
}

function Show-CocopilotModelCatalog {
    param([Parameter(Mandatory)][object[]]$Catalog)

    $source = if (@($Catalog | Where-Object { $_.Source -eq "account" }).Count -eq $Catalog.Count) {
        "available to the current Copilot account"
    } else {
        "advertised by the installed Copilot CLI (account availability unknown)"
    }
    Write-Host "`nModels $source`n" -ForegroundColor Cyan
    Get-CocopilotModelDisplayRows -Catalog $Catalog |
        Format-Table Number, Model, Effort, Context, Output, Category, Price -Wrap -AutoSize |
        Out-Host
}

function Read-CocopilotModelChoice {
    param(
        [Parameter(Mandatory)][object[]]$Catalog,
        [Parameter(Mandatory)][string]$RoleLabel,
        [string]$DefaultModelId
    )

    if ($Catalog.Count -eq 0) { throw "No Copilot models are available to select." }

    $default = $Catalog | Where-Object { $_.Id -ieq $DefaultModelId } | Select-Object -First 1
    if (-not $default) {
        $default = $Catalog | Where-Object { $_.Id -ne "auto" } | Select-Object -First 1
    }
    if (-not $default) { $default = $Catalog[0] }
    $defaultNumber = [array]::IndexOf($Catalog, $default) + 1

    while ($true) {
        $answer = Read-Host "$RoleLabel model (number or id) [$defaultNumber]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $default }

        $selectedNumber = 0
        if ([int]::TryParse($answer, [ref]$selectedNumber) -and $selectedNumber -ge 1 -and $selectedNumber -le $Catalog.Count) {
            return $Catalog[$selectedNumber - 1]
        }

        $selected = $Catalog | Where-Object { $_.Id -ieq $answer.Trim() } | Select-Object -First 1
        if ($selected) { return $selected }
        Write-Warning "Choose a model number from 1 to $($Catalog.Count), or enter an exact model id."
    }
}

function Read-CocopilotOptionalSetting {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Choices,
        [string]$DefaultValue
    )

    $displayDefault = if ($DefaultValue) { $DefaultValue } else { "cli-default" }
    $displayChoices = @("cli-default") + @($Choices)
    while ($true) {
        $answer = Read-Host "$Prompt ($($displayChoices -join ', ')) [$displayDefault]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultValue }
        if ($answer.Trim() -ieq "cli-default") { return $null }

        $selected = $Choices | Where-Object { $_ -ieq $answer.Trim() } | Select-Object -First 1
        if ($selected) { return $selected }
        Write-Warning "Choose one of: $($displayChoices -join ', ')."
    }
}

function Get-CocopilotStrongestEffort {
    <#
    .SYNOPSIS
        The strongest known effort among a model's supported values, by the
        fixed ranking max > xhigh > high > medium > low > minimal > none -
        independent of the SDK's array order and its default. Values outside
        the ranking are returned separately, so a caller can show them rather
        than guess where they rank.
    #>
    param([string[]]$SupportedEfforts)

    $ranking = @("max", "xhigh", "high", "medium", "low", "minimal", "none")
    $supported = @($SupportedEfforts | Where-Object { $_ })
    return [pscustomobject]@{
        Strongest = $ranking | Where-Object { $_ -in $supported } | Select-Object -First 1
        Unknown   = @($supported | Where-Object { $_ -notin $ranking })
    }
}

function Resolve-CocopilotAgentModelConfiguration {
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$RoleLabel,
        [string]$RequestedEffort,
        [string]$RequestedContext,
        [switch]$PromptForSettings
    )

    $isAuto = $Model.Id -eq "auto"
    $supportedEfforts = @($Model.SupportedEfforts)
    $supportedContexts = @($Model.ContextTiers)

    if ($RequestedEffort -and $Model.HasCapabilityMetadata -and -not $isAuto -and $RequestedEffort -notin $supportedEfforts) {
        $supported = if ($supportedEfforts.Count -gt 0) { $supportedEfforts -join ", " } else { "none" }
        throw "Model '$($Model.Id)' does not support effort '$RequestedEffort' (supported: $supported)."
    }
    if ($RequestedContext -and $Model.HasCapabilityMetadata -and -not $isAuto -and $RequestedContext -notin $supportedContexts) {
        $supported = if ($supportedContexts.Count -gt 0) { $supportedContexts -join ", " } else { "none" }
        throw "Model '$($Model.Id)' does not support context tier '$RequestedContext' (supported: $supported)."
    }

    $effort = $RequestedEffort
    $context = $RequestedContext
    if ($PromptForSettings -and -not $isAuto) {
        if (-not $effort) {
            if ($Model.HasCapabilityMetadata -and $supportedEfforts.Count -gt 0) {
                $ranked = Get-CocopilotStrongestEffort -SupportedEfforts $supportedEfforts
                if ($ranked.Unknown.Count -gt 0) {
                    $defaultNote = if ($ranked.Strongest) { "the default is the strongest known value, '$($ranked.Strongest)'" } else { "no default is preselected" }
                    Write-Warning "$($RoleLabel): model '$($Model.Id)' also advertises effort values cocopilot cannot rank ($($ranked.Unknown -join ', ')); $defaultNote."
                }
                $effort = Read-CocopilotOptionalSetting -Prompt "$RoleLabel effort" -Choices $supportedEfforts -DefaultValue $ranked.Strongest
            } elseif (-not $Model.HasCapabilityMetadata) {
                $effort = Read-CocopilotOptionalSetting -Prompt "$RoleLabel effort" `
                    -Choices @("none", "minimal", "low", "medium", "high", "xhigh", "max")
            }
        }

        if (-not $context) {
            if ($Model.HasCapabilityMetadata -and "long_context" -in $supportedContexts) {
                $context = Read-CocopilotOptionalSetting -Prompt "$RoleLabel context" `
                    -Choices $supportedContexts -DefaultValue "long_context"
            } elseif (-not $Model.HasCapabilityMetadata) {
                $context = Read-CocopilotOptionalSetting -Prompt "$RoleLabel context" `
                    -Choices @("default", "long_context")
            }
        }
    }

    return [pscustomobject]@{
        Model   = $Model.Id
        Effort  = $effort
        Context = $context
    }
}

function New-CocopilotAgentArguments {
    param(
        [Parameter(Mandatory)][string]$Model,
        [string]$Effort,
        [string]$Context
    )

    $arguments = @("--model", $Model)
    if ($Effort) { $arguments += @("--effort", $Effort) }
    if ($Context) { $arguments += @("--context", $Context) }
    $arguments += @("--autopilot", "--allow-all")
    return [string[]]$arguments
}

function Get-CocopilotArgumentValue {
    param(
        [string[]]$Arguments,
        [Parameter(Mandatory)][string]$Name
    )

    for ($index = 0; $index -lt @($Arguments).Count - 1; $index++) {
        if ($Arguments[$index] -eq $Name) { return $Arguments[$index + 1] }
    }
    return
}
