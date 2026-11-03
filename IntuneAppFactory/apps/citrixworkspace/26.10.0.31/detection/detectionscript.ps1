#requires -Version 5.1
# Example for the x64 Notepad++ package; configure runAs32Bit: false.
# Save as UTF-8 with BOM, particularly if adding non-ASCII text.
$minimumVersion = [version]'8.9.7'
try {
    $installed = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++' -Name DisplayVersion -ErrorAction Stop
    if ([version]$installed.DisplayVersion -ge $minimumVersion) {
        Write-Output "Notepad++ $($installed.DisplayVersion) detected"
        exit 0
    }
}
catch {
    # Missing key, missing version or unreadable version means not detected.
    # Do not write to STDERR: Intune treats error output as detection failure.
    exit 1
}
exit 1
