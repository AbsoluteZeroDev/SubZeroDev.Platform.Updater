$ErrorActionPreference = 'Stop'
# Runs after the tests: packs and restores the sample consumers, then verifies the distribution formats and a packaged portable A to B to C update.
& "$PSScriptRoot/Test-Package.ps1" -NoTest
& "$PSScriptRoot/Pack-Application.ps1" -Project tests/UpdaterProbe/UpdaterProbe.csproj -AppId SubZeroDev.UpdaterProbe -MainExe UpdaterProbe.exe -Version 1.0.0 -ReleaseNotes README.md -OutputDirectory artifacts/probe -NuGetConfig artifacts/consumer.nuget.config
& "$PSScriptRoot/Test-PortableUpdate.ps1" -NuGetConfig artifacts/consumer.nuget.config
