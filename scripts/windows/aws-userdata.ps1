<powershell>
# EC2 user data for Windows builds: turn on WinRM over HTTPS (self-signed
# certificate) so Packer can connect. The listener is removed again by
# EC2Launch sysprep before the AMI is captured.
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTP' } | Remove-Item -Recurse -Force
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
Set-Item WSMan:\localhost\MaxTimeoutms -Value 1800000
New-NetFirewallRule -DisplayName 'WinRM HTTPS (Packer build)' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow | Out-Null
Restart-Service WinRM
</powershell>
