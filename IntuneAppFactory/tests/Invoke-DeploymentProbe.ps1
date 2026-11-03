#requires -Version 5.1
# Test-only boundary mocks. The generated entry script runs, but no toolkit module,
# installer, process-closing operation, or UI is executed.
function Invoke-DeploymentProbe($PackageRoot, [hashtable]$Parameters = @{}, [switch]$FailProcess, [switch]$UseDefaultMsi) {
    $state = [pscustomobject]@{
        Package=$PackageRoot; Opened=$null; Session=$null; FailProcess=[bool]$FailProcess; UseDefaultMsi=[bool]$UseDefaultMsi
        Calls=(New-Object 'System.Collections.Generic.List[object]')
        Welcome=(New-Object 'System.Collections.Generic.List[object]')
        Prompts=(New-Object 'System.Collections.Generic.List[object]')
        ExitCodes=(New-Object 'System.Collections.Generic.List[int]')
        Errors=(New-Object 'System.Collections.Generic.List[string]')
        Imports=(New-Object 'System.Collections.Generic.List[string]')
    }
    $mockModule = New-Module -Name DeploymentProbe -ArgumentList $state -ScriptBlock {
        param($State)
        $script:state = $State
        function Import-Module {
            [CmdletBinding()]param($FullyQualifiedName,$Name,[switch]$Force)
            $script:state.Imports.Add($(if ($FullyQualifiedName) { $FullyQualifiedName.ModuleName } else { $Name }))
        }
        function Unblock-File { [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject) process {} }
        function Get-ADTBoundParametersAndDefaultValues {
            param($Invocation)
            $result = @{}
            foreach ($key in $Invocation.BoundParameters.Keys) { $result[$key] = $Invocation.BoundParameters[$key] }
            return $result
        }
        function Remove-ADTHashtableNullOrEmptyValues {
            param($Hashtable)
            $result = @{}
            foreach ($pair in $Hashtable.GetEnumerator()) {
                if (-not [string]::IsNullOrWhiteSpace(($pair.Value | Out-String))) { $result[$pair.Key] = $pair.Value }
            }
            return $result
        }
        function Open-ADTSession {
            [CmdletBinding()]
            param($AppVendor,$AppName,$AppVersion,$AppArch,$AppLang,$AppRevision,$AppSuccessExitCodes,$AppRebootExitCodes,
                [ValidateNotNullOrEmpty()][object[]]$AppProcessesToClose,$AppScriptVersion,$AppScriptDate,$AppScriptAuthor,
                $RequireAdmin,$InstallName,$InstallTitle,$DeployAppScriptFriendlyName,$DeployAppScriptVersion,$DeployAppScriptParameters,
                $DeploymentType='Install',$DeployMode,[switch]$SuppressRebootPassThru,[switch]$TerminalServerMode,[switch]$DisableLogging,[switch]$PassThru)
            $script:state.Opened = $PSBoundParameters
            $script:state.Session = [pscustomobject]@{DeploymentType=$DeploymentType;DeployMode=$DeployMode;DirFiles=(Join-Path $script:state.Package 'Files');AppProcessesToClose=@($AppProcessesToClose | Where-Object { $null -ne $_ });UseDefaultMsi=$script:state.UseDefaultMsi;DefaultMsiFile='fixture.msi';DefaultMstFile=$null;DefaultMspFiles=@();InstallPhase=''}
            return $script:state.Session
        }
        function Close-ADTSession { param([int]$ExitCode=0) $script:state.ExitCodes.Add($ExitCode) }
        function Resolve-ADTErrorRecord { param($ErrorRecord) return $ErrorRecord.Exception.Message }
        function Write-ADTLogEntry { param($Message,$Severity) $script:state.Errors.Add($Message) }
        function Show-ADTInstallationProgress { }
        function Show-ADTInstallationWelcome {
            [CmdletBinding()]
            param($CloseProcesses,$CloseProcessesCountdown,[switch]$AllowDefer,$DeferTimes,$DeferRunInterval,[switch]$CheckDiskSpace,[switch]$PersistPrompt)
            $script:state.Welcome.Add($PSBoundParameters)
        }
        function Show-ADTInstallationPrompt {
            [CmdletBinding()]param([ValidateNotNullOrEmpty()][string]$Message,$ButtonRightText,[switch]$NoWait)
            $script:state.Prompts.Add($PSBoundParameters)
        }
        function Start-ADTMsiProcess {
            [CmdletBinding()]
            param($Action,$RepairMode,$FilePath,$ProductCode,[ValidateNotNullOrEmpty()][string[]]$ArgumentList,[switch]$ExitOnProcessFailure)
            $script:state.Calls.Add($PSBoundParameters)
            if ($script:state.FailProcess) { throw 'Simulated installer failure.' }
        }
        function Start-ADTProcess {
            [CmdletBinding()]
            param($FilePath,[ValidateNotNullOrEmpty()][string[]]$ArgumentList,$WorkingDirectory,[switch]$ExitOnProcessFailure)
            $script:state.Calls.Add($PSBoundParameters)
            if ($script:state.FailProcess) { throw 'Simulated installer failure.' }
        }
        Export-ModuleMember -Function *
    }
    Microsoft.PowerShell.Core\Import-Module -ModuleInfo $mockModule -Scope Local -Force
    try { & (Join-Path $PackageRoot 'Invoke-AppDeployToolkit.ps1') @Parameters }
    finally { Microsoft.PowerShell.Core\Remove-Module -ModuleInfo $mockModule -Force }
    return $state
}
