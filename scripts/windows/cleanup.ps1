# Tidy the Windows image before it's generalised.
$ErrorActionPreference = 'Continue'
Write-Output "[cleanup] Windows Update download cache"
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force 'C:\Windows\SoftwareDistribution\Download\*' -ErrorAction SilentlyContinue
Start-Service -Name wuauserv -ErrorAction SilentlyContinue

Write-Output "[cleanup] component store (superseded updates)"
& dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null

Write-Output "[cleanup] temp files and SBOM working files"
Remove-Item -Recurse -Force 'C:\Windows\Temp\sbom' -ErrorAction SilentlyContinue
Get-ChildItem 'C:\Windows\Temp', $env:TEMP -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Output "[cleanup] event logs"
wevtutil el | ForEach-Object { wevtutil cl "$_" 2>$null }
Write-Output "[cleanup] complete"
exit 0
