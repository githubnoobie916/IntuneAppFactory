##ndadobe msi install GUID is different depending if MSI or EXE is used, even when the version number is the same.

$globalprotectapp = Get-WmiObject Win32_Product | 
Where-Object {
    $_.Name -match 'Globalprotect' -and 
    $_.Version -eq '6.3.3' -and
    $_.IdentifyingNumber -eq {CD809CD6-9D01-417E-9E76-D19EEE77E74F}
}

if ($globalprotectapp){
    write-host "Globalprotect is installed"
    exit 0
}
else {
    write-host "Globalprotect was not detected"
    exit 1
}