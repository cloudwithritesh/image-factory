# Generalise for AWS with EC2Launch v2 (Windows Server 2022 AMIs ship it):
# reset clears instance state; sysprep generalises without shutting down,
# Packer then stops the instance and creates the AMI.
$ErrorActionPreference = 'Stop'
$ec2launch = Join-Path $env:ProgramFiles 'Amazon\EC2Launch\ec2launch.exe'
if (-not (Test-Path $ec2launch)) { throw "EC2Launch v2 not found at $ec2launch" }
Write-Output "[sysprep] EC2Launch reset"
& $ec2launch reset --block
Write-Output "[sysprep] EC2Launch sysprep"
& $ec2launch sysprep --block
if ($LASTEXITCODE -ne 0) { throw "ec2launch sysprep failed ($LASTEXITCODE)" }
Write-Output "[sysprep] done"
