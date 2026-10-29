$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
# Portable collection tests. No installer, signing key generation or GitHub upload runs here.
. "$PSScriptRoot/../../scripts/ProbeEvidence.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('probe-bundle-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Set-FixtureFile([string]$Relative, [string]$Value = 'diagnostic') {
    $path = Join-Path $smoke $Relative
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    Set-Content -LiteralPath $path -Value $Value
}
function Assert-ProbeFailure([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch {
        if ($_.Exception.Message -like "*$Message*") { return }
        throw "Unexpected error: $($_.Exception.Message); expected $Message"
    }
    throw "Expected error: $Message"
}
try {
    $smoke = Join-Path $testRoot 'smoke'; $bundle = Join-Path $testRoot 'bundle'
    $expected = @(
        'MSI/msi-lifecycle.json', 'MSI/msi-install.log', 'MSI/msi-uninstall.log',
        'MSI-Repair/msi-repair.json', 'MSI-Repair/msi-install.log',
        'MSI-Repair/msi-repair.log', 'MSI-Repair/msi-uninstall.log',
        'MSI-Repair/preserved data/repair-observation.json'
    )
    Invoke-WithProbeEvidence -SmokeDirectory $smoke -Destination $bundle -Probe {
        foreach ($name in $expected) { Set-FixtureFile $name }
        foreach ($name in @('MSI-Repair/preserved data/control.json', 'MSI-Repair/preserved data/updater.json',
            'MSI/unrelated.json', '1.0.0/assets/probe.msi', 'key.pem', 'probe.nupkg', 'unrelated.log')) {
            Set-FixtureFile $name 'SigningKey-do-not-upload'
        }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $bundle 'bundle-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Collected.Count -ne 8 -or $manifest.Missing.Count -or $manifest.Failed.Count) { throw 'Incomplete success bundle.' }
    $files = @(Get-ChildItem -LiteralPath $bundle -File -Recurse)
    if ($files.Count -ne 9) { throw 'Bundle included non-allowlisted files.' }
    foreach ($entry in $manifest.Collected) {
        $target = Join-Path $bundle $entry.Path
        if ($entry.Path -notin $expected -or $entry.Sha256 -ne (Get-FileHash -LiteralPath $target).Hash) { throw 'Wrong bundle identity or hash.' }
    }
    if (($files | Get-Content -Raw) -match 'SigningKey-do-not-upload') { throw 'Signing material escaped into evidence.' }

    # A failed probe preserves all available partial evidence and its original error.
    Remove-Item -LiteralPath $smoke -Recurse -Force
    Assert-ProbeFailure {
        Invoke-WithProbeEvidence -SmokeDirectory $smoke -Destination $bundle -Probe {
            Set-FixtureFile 'MSI-Repair/msi-install.log' 'partial install'
            Set-FixtureFile 'MSI-Repair/msi-repair.json' '{"Status":"Failed","Error":"original probe failure"}'
            throw 'original probe failure'
        }
    } 'original probe failure'
    $manifest = Get-Content -LiteralPath (Join-Path $bundle 'bundle-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Collected.Count -ne 2 -or $manifest.Missing.Count -ne 6 -or $manifest.Failed.Count) { throw 'Partial evidence was lost.' }
    if (Test-Path -LiteralPath (Join-Path $bundle 'MSI/msi-install.log')) { throw 'Previous run evidence survived.' }

    # Rejected stale smoke data must not be uploaded, even if it is allowlisted.
    Assert-ProbeFailure { Invoke-WithProbeEvidence -SmokeDirectory $smoke -Destination $bundle -Probe { throw 'must not run' } } 'fresh smoke'
    $manifest = Get-Content -LiteralPath (Join-Path $bundle 'bundle-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Collected.Count -or $manifest.Missing.Count -ne 8) { throw 'Stale smoke evidence was collected.' }

    Remove-Item -LiteralPath $smoke -Recurse -Force
    Assert-ProbeFailure {
        Invoke-WithProbeEvidence -SmokeDirectory $smoke -Destination $bundle -Probe { throw 'packaging failed before MSI' }
    } 'packaging failed before MSI'
    $manifest = Get-Content -LiteralPath (Join-Path $bundle 'bundle-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Collected.Count -or $manifest.Missing.Count -ne 8) { throw 'Early failure fabricated evidence.' }

    # Links cannot redirect an allowed name to a control file or an unrelated tree.
    Invoke-WithProbeEvidence -SmokeDirectory $smoke -Destination $bundle -Probe {
        Set-FixtureFile 'MSI/msi-install.log'
    }
    $outside = Join-Path $testRoot 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    Set-Content -LiteralPath (Join-Path $outside 'msi-repair.json') -Value 'SigningKey-do-not-upload'
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path (Join-Path $smoke 'MSI-Repair') -Target $outside | Out-Null
    Assert-ProbeFailure { Export-ProbeEvidence $smoke $bundle 3>$null } 'Failed to collect'
    if (Test-Path -LiteralPath (Join-Path $bundle 'MSI-Repair/msi-repair.json')) { throw 'Linked evidence was copied.' }
    Remove-Item -LiteralPath (Join-Path $smoke 'MSI-Repair') -Force
    Remove-Item -LiteralPath $smoke -Recurse -Force

    # Run the actual distribution entry point in a child process with packaging/OS boundaries
    # stubbed. This catches wrapper wiring and exit-code regressions, not just helper behavior.
    $fixture = Join-Path $testRoot 'distribution'
    New-Item -ItemType Directory -Path "$fixture/scripts", "$fixture/tests/UpdaterProbe" -Force | Out-Null
    foreach ($name in @('ProbeEvidence.ps1', 'Test-Distribution.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../../scripts/$name") -Destination "$fixture/scripts/$name"
    }
    foreach ($name in @('Test-Package.ps1', 'Pack-Application.ps1', 'Test-PortableUpdate.ps1')) {
        Set-Content -LiteralPath "$fixture/scripts/$name" -Value '# mocked packaging boundary'
    }
    foreach ($name in @('Test-ProbeEvidence.ps1', 'Test-MsiRepairEvidence.ps1')) {
        Set-Content -LiteralPath "$fixture/tests/UpdaterProbe/$name" -Value '# already tested; avoid recursive fixture tests'
    }
    foreach ($fail in @($false, $true)) {
        $probeScript = @'
New-Item -ItemType Directory -Path artifacts/installer-smoke/MSI-Repair -Force | Out-Null
Set-Content -LiteralPath artifacts/installer-smoke/MSI-Repair/msi-install.log -Value 'fixture install log'
Set-Content -LiteralPath artifacts/installer-smoke/MSI-Repair/msi-repair.json -Value '{"fixture":true}'
'@
        if ($fail) { $probeScript += "`nthrow 'distribution primary failure'" }
        Set-Content -LiteralPath "$fixture/scripts/Test-InstalledUpdate.ps1" -Value $probeScript
        Push-Location $fixture
        try {
            $output = & (Join-Path $PSHOME 'pwsh') -NoProfile -File scripts/Test-Distribution.ps1 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } finally { Pop-Location }
        if (($fail -and ($exitCode -eq 0 -or $output -notlike '*distribution primary failure*')) -or
            (-not $fail -and $exitCode -ne 0)) { throw "Distribution exit status changed: $output" }
        $report = Get-Content -LiteralPath "$fixture/artifacts/probe-evidence/bundle-manifest.json" -Raw | ConvertFrom-Json
        if ($report.Collected.Count -ne 2 -or $report.Missing.Count -ne 6) { throw 'Distribution did not stage partial evidence.' }
        Remove-Item -LiteralPath "$fixture/artifacts" -Recurse -Force
    }

    # A secondary collector failure fails success, but never replaces a probe failure.
    function Export-ProbeEvidence { throw 'collector failure' }
    Assert-ProbeFailure { Invoke-WithProbeEvidence -SmokeDirectory $smoke -Destination $bundle -Probe {} } 'collector failure'
    Assert-ProbeFailure {
        Invoke-WithProbeEvidence -SmokeDirectory $smoke -Destination $bundle -Probe { throw 'primary failure' } 3>$null
    } 'primary failure'
    Assert-ProbeFailure { Invoke-WithProbeEvidence -SmokeDirectory $smoke -Destination $smoke -Probe {} } 'must not overlap'
    Write-Output 'Probe evidence collection tests passed (no MSI execution or GitHub upload).'
} finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }
