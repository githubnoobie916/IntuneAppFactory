$infoblox = Get-WmiObject Win32_Product | Where-Object {$_.Name -match "BloxOne® Endpoint"}

if ($infoblox -and $infoblox.version -gt '2.6.0.0')
{
    write-output 'Infoblox version greater then 2.6.0.0 detected'
    exit 0
}
exit 1