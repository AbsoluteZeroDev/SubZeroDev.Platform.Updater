$ErrorActionPreference = 'Stop'
# The shared workflow's script runner turns a native command's non-zero exit into an error; these scripts check $LASTEXITCODE themselves.
$PSNativeCommandUseErrorActionPreference = $false
# Runs after the tests: packs and restores the sample consumers, then verifies the distribution formats and packaged portable, Setup, and MSI updates.
& "$PSScriptRoot/../tests/UpdaterProbe/Test-MsiRepairEvidence.ps1"
& "$PSScriptRoot/Test-Package.ps1" -NoTest
& "$PSScriptRoot/Pack-Application.ps1" -Project tests/UpdaterProbe/UpdaterProbe.csproj -AppId SubZeroDev.UpdaterProbe -MainExe UpdaterProbe.exe -Version 1.0.0 -ReleaseNotes README.md -OutputDirectory artifacts/probe -NuGetConfig artifacts/consumer.nuget.config
& "$PSScriptRoot/Test-PortableUpdate.ps1" -NuGetConfig artifacts/consumer.nuget.config
try {
    & "$PSScriptRoot/Test-InstalledUpdate.ps1" -NuGetConfig artifacts/consumer.nuget.config
} finally {
    # The shared workflow uploads TRX files only. Retain machine-readable repair evidence in
    # its job log as well as on disk, including when the installed-case script fails.
    $repairEvidence = 'artifacts/installer-smoke/MSI-Repair/msi-repair.json'
    if (Test-Path -LiteralPath $repairEvidence) { Get-Content -LiteralPath $repairEvidence -Raw | Write-Output }
}
