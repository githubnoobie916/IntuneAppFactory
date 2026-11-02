# Microsoft Win32 Content Prep Tool

Run `../scripts/Install-IntuneWinTool.ps1` to stage `IntuneWinAppUtil.exe`, Microsoft's license PDF, and `IntuneWinAppUtil.provenance.json` here. The script accepts `-Force` to replace an existing copy after validating the download. Builds do not download the tool automatically.

The pinned release is [v1.8.7](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/tag/v1.8.7), commit `1d6cfcbdf8c28edc596337031f74df951f38f718`, from the official `microsoft/Microsoft-Win32-Content-Prep-Tool` repository linked by [Microsoft Learn](https://learn.microsoft.com/intune/app-management/deployment/create-win32-package).

Expected executable SHA-256:

```text
C1BA45B5CB939E84AF064BB7FF4B38FB3DFE33C8DC1078FD9B157672EAE671F6
```

The installer verifies this hash and a valid Microsoft Authenticode signature before placing the executable here. Every packaging run checks the hash again, including when an alternate tool path is supplied. The fixed hash allows subsequent packaging without network access. To update the pin, review the official release and verify the new executable's source, hash and signature, then update `Get-FactoryIntuneWinRelease` in `scripts/IntuneWin.ps1` and this document together.

Requires Windows and .NET Framework 4.7.2 or later. Review the downloaded Microsoft license terms; the upstream project states that downloading and using the tool constitutes acceptance. Downloaded files are excluded from Git. Keep this directory outside every packaging source.
