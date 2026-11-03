$java = Get-WmiObject Win32_Product | Where-Object {$_.Name -match "Java 8"}

if ($java -and $java.version -gt '8.0.5030.0')
{
    write-output 'Java version greater then 8.0.5030.0 detected'
    exit 0
}
exit 1