# Generate the SBOM on the Windows build VM with Syft (CycloneDX + SPDX).
# The binary is checksum-verified, used once and removed, so it doesn't
# ship in the image. Syft catalogs installed programs, .NET, Java, Python,
# Node and Go packages; Windows OS patches (KBs) are reported separately
# in C:\ProgramData\image-factory\build-info.json by Ansible.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
foreach ($v in 'SYFT_VERSION', 'IMAGE_NAME', 'IMAGE_VERSION') {
  if (-not [Environment]::GetEnvironmentVariable($v)) { throw "$v is required" }
}
$ver = $env:SYFT_VERSION
$tool = 'C:\Windows\Temp\sbom-tool'
$out = 'C:\Windows\Temp\sbom'
Remove-Item -Recurse -Force $tool, $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tool, $out | Out-Null

$base = "https://github.com/anchore/syft/releases/download/v$ver"
$zip = "syft_${ver}_windows_amd64.zip"
Write-Output "[sbom] downloading Syft $ver"
Invoke-WebRequest -UseBasicParsing "$base/$zip" -OutFile "$tool\$zip"
Invoke-WebRequest -UseBasicParsing "$base/syft_${ver}_checksums.txt" -OutFile "$tool\checksums.txt"
$expected = (Select-String -Path "$tool\checksums.txt" -Pattern " $([regex]::Escape($zip))$").Line.Split(' ')[0]
$actual = (Get-FileHash -Algorithm SHA256 "$tool\$zip").Hash.ToLower()
if ($expected -ne $actual) { throw "syft checksum mismatch: expected $expected, got $actual" }
Expand-Archive -Path "$tool\$zip" -DestinationPath $tool -Force

Write-Output "[sbom] scanning C:\"
& "$tool\syft.exe" scan 'dir:C:\' `
  --source-name $env:IMAGE_NAME --source-version $env:IMAGE_VERSION `
  --exclude './Windows/WinSxS/**' --exclude './Windows/Temp/**' `
  --exclude './$Recycle.Bin/**' --exclude './System Volume Information/**' `
  --exclude './pagefile.sys' --exclude './swapfile.sys' `
  -o "cyclonedx-json=$out\sbom.cdx.json" -o "spdx-json=$out\sbom.spdx.json"
if ($LASTEXITCODE -ne 0) { throw "syft failed with exit code $LASTEXITCODE" }

Remove-Item -Recurse -Force $tool
Write-Output ("[sbom] written: {0:N0} KB CycloneDX, {1:N0} KB SPDX" -f ((Get-Item "$out\sbom.cdx.json").Length / 1KB), ((Get-Item "$out\sbom.spdx.json").Length / 1KB))
