# Generalise for Azure (Microsoft's documented sequence): wait for the
# guest agent, sysprep /generalize /oobe, then wait for the reseal state.
$ErrorActionPreference = 'Stop'
foreach ($svc in 'RdAgent', 'WindowsAzureGuestAgent') {
  while ((Get-Service $svc).Status -ne 'Running') { Write-Output "[sysprep] waiting for $svc"; Start-Sleep -Seconds 5 }
}
Write-Output "[sysprep] running sysprep /generalize /oobe /mode:vm"
& "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /oobe /generalize /quiet /quit /mode:vm
while ($true) {
  $state = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
  if ($state -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
  Write-Output "[sysprep] image state: $state"
  Start-Sleep -Seconds 10
}
Write-Output "[sysprep] done"
