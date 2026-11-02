#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$scriptPath = [IO.Path]::GetFullPath("$PSScriptRoot/../apps/globalprotect/6.3.3-711/detection/detectionscript.ps1")
$hosts = @((Join-Path $PSHOME 'pwsh.exe'))
if ($env:WINDIR) { $hosts += Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe' }
foreach ($hostPath in $hosts) {
    foreach ($scenario in @('Installed','Absent','WrongVersion','WrongProduct','Wow6432')) {
        $output = & $hostPath -NoProfile -File "$PSScriptRoot/Invoke-DetectionProbe.ps1" -ScriptPath $scriptPath -Scenario $scenario
        $code = $LASTEXITCODE
        $detected = $scenario -in @('Installed','Wow6432')
        if ($detected -and ($code -ne 0 -or ($output -join '') -ne 'GlobalProtect 6.3.3 detected')) { throw "Detection failed: $scenario ($hostPath)." }
        if (-not $detected -and ($code -ne 1 -or $output)) { throw "Detection false positive: $scenario ($hostPath)." }
        Write-Host "PASS $scenario ($(Split-Path $hostPath -Leaf))"
    }
}
