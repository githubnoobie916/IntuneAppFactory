Copy-ADTFileToUserProfiles [-Path] <String[]> [[-Destination] <String>] [-BasePath <String>] [-Recurse]
 [-Flatten] [-FileCopyMode <String>] [-RobocopyParams <String>] [-RobocopyAdditionalParams <String>]
 [-ExcludeNTAccount <String[]>] [-IncludeSystemProfiles] [-IncludeServiceProfiles] [-ExcludeDefaultUser]
 [-ContinueFileCopyOnError] [<CommonParameters>]


 ##Add into post-install section of generated output.

 Copy-ADTFileToUserProfiles -Path "$($adtSession.DirFiles)\exception.sites" -Destination "AppData\LocalLow\Sun\Java\Deployment\security"


 COPY exception.sites to the files folder.


 #Custom uninstall logic. Put into uninstall section. .EXE does not have an uninstall flag and must use msiexe or uninstall-adtapplication.

 $Java8 = Get-ADTApplication -Name 'Java 8' -ApplicationType MSI -FilterScript {
    $_.Publisher -eq 'Oracle Corporation' -and
    $_.DisplayName -match '^Java 8 Update \d+ \(64-bit\)$' -and
    $_.Is64BitApplication -eq $true
}

if ($Java8) {
    $Java8 | Uninstall-ADTApplication
}


#manually added process to close, or else the install would run under interactivemode