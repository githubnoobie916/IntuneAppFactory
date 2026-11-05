$adobe = Get-WmiObject Win32_Product | Where-Object {$_.Name -match "Adobe Acrobat"}

if ($adobe -and $adobe.version -gt '26.002.22030')
{
    write-output 'Adobe version greater then 26.002.22030 detected'
    exit 0
}
exit 1