#requires -Version 5.1
# Build-time renderer for the unmodified upstream entry script. No helpers are shipped.
function ConvertTo-FactoryPowerShellLiteral($Value) {
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [string]) { return "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'" }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [array]) { return '@(' + (@(foreach ($item in $Value) { ConvertTo-FactoryPowerShellLiteral $item }) -join ', ') + ')' }
    if ($Value -is [int] -or $Value -is [long]) { return $Value.ToString([Globalization.CultureInfo]::InvariantCulture) }
    throw 'Unsupported PowerShell literal type.'
}

function Get-FactoryDeploymentSteps([string]$Action, $Steps) {
    foreach ($step in $Steps) {
        if ($step.path) {
            '    $installerPath = Join-Path $adtSession.DirFiles ' + (ConvertTo-FactoryPowerShellLiteral $step.path)
        }
        elseif ($step.executable) {
            '    $installerPath = [Environment]::ExpandEnvironmentVariables(' + (ConvertTo-FactoryPowerShellLiteral $step.executable) + ')'
            '    if ($installerPath -match ''%[^%]+%'' -or -not [IO.Path]::IsPathRooted($installerPath)) { throw "Unresolved executable path: $installerPath" }'
        }
        $target = if ($step.productCode) { '-ProductCode ' + (ConvertTo-FactoryPowerShellLiteral $step.productCode) } else { '-FilePath $installerPath' }
        $arguments = if ($step.arguments.Length) { ' -ArgumentList ' + (ConvertTo-FactoryPowerShellLiteral $step.arguments) } else { '' }
        if ($step.type -eq 'MSI') {
            # Native Repair mode uses /f; the Reinstall default would lose REINSTALL
            # properties when the user supplies an explicit ArgumentList.
            $repair = if ($Action -eq 'Repair') { ' -RepairMode Repair' } else { '' }
            "    Start-ADTMsiProcess -Action $Action$repair $target$arguments -ExitOnProcessFailure -ErrorAction Stop"
        }
        else { "    Start-ADTProcess $target$arguments -WorkingDirectory (Split-Path `$installerPath -Parent) -ExitOnProcessFailure -ErrorAction Stop" }
    }
}

function Update-FactoryDeploymentTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Config)
    $source = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $newline = if ($source.Contains("`r`n")) { "`r`n" } else { "`n" }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    if ($errors) { throw 'Source template has syntax errors. Use the unmodified PSADT v4 template.' }
    $edits = New-Object 'System.Collections.Generic.List[object]'
    function Add-TemplateEdit([string]$Pattern, [string]$Text, [int]$ExpectedCount = 1) {
        $matches = [regex]::Matches($source, $Pattern)
        if ($matches.Count -ne $ExpectedCount) { throw "Unexpected template structure: expected $ExpectedCount match(es) for '$Pattern', found $($matches.Count)." }
        foreach ($match in $matches) { $edits.Add(@{Start=$match.Index;Length=$match.Length;Text=$Text}) }
    }
    $options = $Config.psadt
    $processes = '@(' + (@(foreach ($process in $options.processesToClose) {
        '@{ Name = ' + (ConvertTo-FactoryPowerShellLiteral $process.name) + '; Description = ' + (ConvertTo-FactoryPowerShellLiteral $process.description) + ' }'
    }) -join ', ') + ')'
    $values = @{
        AppVendor=$Config.publisher; AppName=$Config.name; AppVersion=$Config.version; AppArch=$Config.architecture
        AppLang=$Config.language; AppRevision=$Config.revision; AppScriptAuthor=$options.scriptAuthor
        AppScriptVersion=$options.scriptVersion; AppScriptDate=$options.scriptDate
        AppSuccessExitCodes=$options.successExitCodes; AppRebootExitCodes=$options.rebootExitCodes
        RequireAdmin=($Config.intune.installContext -eq 'system'); InstallName=$options.installName; InstallTitle=$options.installTitle
    }
    $sessions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.HashtableAst] -and 'AppVendor' -in @($node.KeyValuePairs | ForEach-Object { $_.Item1.Value })
    }, $true))
    if ($sessions.Count -ne 1) { throw 'Unexpected template structure: application session table not found exactly once.' }
    foreach ($key in @($values.Keys) + @('AppProcessesToClose')) {
        $pairs = @($sessions[0].KeyValuePairs | Where-Object { $_.Item1.Value -eq $key })
        if ($pairs.Count -ne 1) { throw "Unexpected template structure: session field '$key' not found exactly once." }
        $extent = $pairs[0].Item2.Extent
        $literal = if ($key -eq 'AppProcessesToClose') { $processes } else { ConvertTo-FactoryPowerShellLiteral $values[$key] }
        $edits.Add(@{Start=$extent.StartOffset;Length=($extent.EndOffset-$extent.StartOffset);Text=$literal})
    }
    foreach ($action in @('Install','Uninstall','Repair')) {
        $taskName = switch ($action) { Install { 'Installation' }; Uninstall { 'Uninstallation' }; Repair { 'Repair' } }
        $marker = "    ## <Perform $taskName tasks here>"
        $steps = @(Get-FactoryDeploymentSteps $action $Config.($action.ToLowerInvariant()))
        $text = $marker
        if ($steps.Count) { $text += $newline + ($steps -join $newline) }
        Add-TemplateEdit ([regex]::Escape($marker)) $text
    }
    # Keep the upstream welcome blocks and comments, changing only their settings.
    Add-TemplateEdit '(?m)^        AllowDefer = \$true' ('        AllowDefer = ' + (ConvertTo-FactoryPowerShellLiteral $options.allowDefer))
    foreach ($setting in @('DeferTimes','CheckDiskSpace','PersistPrompt')) {
        Add-TemplateEdit ("(?m)^        $setting = [^\r\n]+") ("        $setting = " + (ConvertTo-FactoryPowerShellLiteral $options.$setting))
    }
    $countdownArgument = ''
    if ('closeProcessesCountdown' -in $options.PSObject.Properties.Name) {
        $addProcesses = "        `$saiwParams.Add('CloseProcesses', `$adtSession.AppProcessesToClose)"
        Add-TemplateEdit ([regex]::Escape($addProcesses)) ($addProcesses + $newline + "        `$saiwParams.Add('CloseProcessesCountdown', $($options.closeProcessesCountdown))")
        $countdownArgument = " -CloseProcessesCountdown $($options.closeProcessesCountdown)"
    }
    Add-TemplateEdit '(?m) -CloseProcessesCountdown 60(?=\r?$)' $countdownArgument 2
    $prompt = $options.completionPrompt
    $promptCommand = '        Show-ADTInstallationPrompt -Message ' + (ConvertTo-FactoryPowerShellLiteral $prompt.message) + ' -ButtonRightText ' + (ConvertTo-FactoryPowerShellLiteral $prompt.buttonRightText) + ' -NoWait:' + (ConvertTo-FactoryPowerShellLiteral $prompt.noWait)
    Add-TemplateEdit '(?m)^        Show-ADTInstallationPrompt -Message [^\r\n]+' $promptCommand
    # Native command-line switches take priority over the generated JSON values.
    # DeployMode belongs exclusively to the launcher; preserve native handling.
    $parameterLine = '    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation'
    $parameterLines = @($parameterLine)
    foreach ($key in @('SuppressRebootPassThru','TerminalServerMode','DisableLogging')) {
        $literal = ConvertTo-FactoryPowerShellLiteral $options.$key
        $parameterLines += "    if (-not `$PSBoundParameters.ContainsKey('$key')) { `$iadtParams['$key'] = $literal }"
    }
    Add-TemplateEdit ([regex]::Escape($parameterLine)) ($parameterLines -join $newline)
    # Apply edits from the end, all located in the ORIGINAL source. Inserted data
    # can never become a new replacement target, even if it contains template text.
    $rendered = $source
    $nextStart = $source.Length
    foreach ($edit in ($edits | Sort-Object { $_.Start } -Descending)) {
        if ($edit.Start + $edit.Length -gt $nextStart) { throw 'Overlapping template edits.' }
        $rendered = $rendered.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text)
        $nextStart = $edit.Start
    }
    $null = [Management.Automation.Language.Parser]::ParseInput($rendered, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Generated deployment has syntax errors: $($errors.Message -join '; ')" }
    [IO.File]::WriteAllText($Path, $rendered, (New-Object Text.UTF8Encoding $true))
}
