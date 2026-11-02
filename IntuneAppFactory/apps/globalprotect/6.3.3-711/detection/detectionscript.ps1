# Standalone Intune detection: product GUID and exact installed version from the reference.
# Read uninstall registration instead of Win32_Product (which can trigger MSI repairs).
$productCode = '{CD809CD6-9D01-417E-9E76-D19EEE77E74F}'
foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
    $app = Get-ItemProperty -LiteralPath "$root\$productCode" -ErrorAction SilentlyContinue
    if ($app -and $app.DisplayName -match 'GlobalProtect' -and $app.DisplayVersion -eq '6.3.3') {
        Write-Output 'GlobalProtect 6.3.3 detected'
        exit 0
    }
}
exit 1
