# CI evidence for the isolated probe only. Never recursively copy the smoke tree:
# control.json carries SigningKey, and packages/signing material are not diagnostics.
function Assert-ProbeEvidencePath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Probe evidence paths must not contain symbolic links or junctions.'
            }
        }
        $current = Split-Path -Path $current -Parent
    }
}

function Export-ProbeEvidence([string]$SmokeDirectory, [string]$Destination) {
    # Exact relative names only; no globs, arbitrary JSON, package assets or preserved data.
    $allowlist = @(
        'MSI/msi-lifecycle.json', 'MSI/msi-install.log', 'MSI/msi-uninstall.log',
        'MSI-Repair/msi-repair.json', 'MSI-Repair/msi-install.log',
        'MSI-Repair/msi-repair.log', 'MSI-Repair/msi-uninstall.log',
        'MSI-Repair/preserved data/repair-observation.json'
    )
    $collected = @(); $missing = @(); $failed = @()
    foreach ($relative in $allowlist) {
        try {
            $source = Join-Path $SmokeDirectory $relative
            Assert-ProbeEvidencePath $source
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $missing += $relative; continue }
            $target = Join-Path $Destination $relative
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop
            $collected += [ordered]@{ Path = $relative; Sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash }
        } catch {
            $failed += $relative
            Write-Warning "Could not collect probe evidence ${relative}: $($_.Exception.Message)"
        }
    }
    [ordered]@{ SchemaVersion = 1; Collected = @($collected); Missing = @($missing); Failed = @($failed) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'bundle-manifest.json')
    if ($failed.Count) { throw "Failed to collect $($failed.Count) probe evidence file(s)." }
}

function Invoke-WithProbeEvidence(
    [scriptblock]$Probe,
    [string]$SmokeDirectory = 'artifacts/installer-smoke',
    [string]$Destination = 'artifacts/probe-evidence'
) {
    $smoke = [IO.Path]::GetFullPath($SmokeDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $bundle = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $separator = [IO.Path]::DirectorySeparatorChar
    if ($bundle -eq $smoke -or $bundle.StartsWith($smoke + $separator, [StringComparison]::OrdinalIgnoreCase) -or
        $smoke.StartsWith($bundle + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Probe source and evidence destination must not overlap.'
    }
    Assert-ProbeEvidencePath $bundle
    # Clear the dedicated staging directory before running anything so retries cannot upload
    # stale or non-allowlisted files, even when packaging fails before MSI starts.
    if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    $probeFailure = $null
    $sourceWasPresent = Test-Path -LiteralPath $smoke
    try {
        # Test-InstalledUpdate itself requires a fresh smoke source.
        if ($sourceWasPresent) { throw 'Use a fresh smoke output directory.' }
        & $Probe
    } catch { $probeFailure = $_; throw } finally {
        try {
            # A stale source rejected above must never be presented as this run's evidence.
            if ($sourceWasPresent) {
                $emptySource = Join-Path $bundle 'not-produced'
                Export-ProbeEvidence $emptySource $bundle
            } else { Export-ProbeEvidence $smoke $bundle }
        } catch {
            if ($probeFailure) { Write-Warning "Evidence collection also failed: $($_.Exception.Message)" }
            else { throw }
        }
    }
}
