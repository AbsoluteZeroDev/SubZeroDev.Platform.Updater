# Helpers for the isolated installed-update probe, not production installer code.
function Invoke-Installer([string]$File, [string[]]$Arguments, [string]$Description, $Operations = $null, [string]$Log) {
    $operation = [ordered]@{ Description = $Description; File = $File; Arguments = $Arguments; Log = $Log
        StartedAtUtc = [DateTime]::UtcNow.ToString('o'); ExitCode = $null; Error = $null }
    if ($null -ne $Operations) { $Operations.Add($operation) }
    try {
        $process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
        $operation.ExitCode = $process.ExitCode
        # Reboot-required codes are recorded but cannot prove an immediately observable repair.
        if ($process.ExitCode -ne 0) { throw "$Description failed with exit code $($process.ExitCode); inspect $root" }
    } catch { $operation.Error = $_.Exception.Message; throw } finally {
        $operation.CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
        $operation.LogExists = [bool]($Log -and (Test-Path -LiteralPath $Log))
    }
}

function Wait-ProbeExit([string]$Installation) {
    $prefix = [IO.Path]::GetFullPath($Installation).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $running = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        if ($running.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Probe processes are still running under $Installation; refusing repair/uninstall."
}

function Get-ProbePreservation([string]$Data) {
    $hashes = [ordered]@{}
    foreach ($name in @('config.json', 'diagnostics.log', 'updater.json')) {
        $path = Join-Path $Data $name
        $hashes[$name] = if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
    }
    $preferences = $null; $readError = $null
    try { $preferences = Get-Content -LiteralPath (Join-Path $Data 'updater.json') -Raw | ConvertFrom-Json } catch { $readError = $_.Exception.Message }
    return [ordered]@{ Hashes = $hashes; ConsentMode = $preferences.consentMode; PendingInstallVersion = $preferences.pendingInstallVersion; ReadError = $readError }
}

function Get-MsiRepairSnapshot([string]$Installation, [string]$Data, [string]$ProductCode, [string]$AppId) {
    $manifest = Join-Path $Installation 'current/sq.version'
    $version = $null; $manifestHash = $null; $binary = $null; $executableHash = $null
    $readErrors = [Collections.Generic.List[string]]::new()
    try {
        [xml]$xml = Get-Content -LiteralPath $manifest -Raw
        $version = $xml.SelectSingleNode("//*[local-name()='metadata']/*[local-name()='version']").InnerText
        $manifestHash = (Get-FileHash -LiteralPath $manifest).Hash
    } catch { $readErrors.Add($_.Exception.Message) }
    $executable = [IO.Path]::GetFullPath((Join-Path $Installation 'current/UpdaterProbe.exe'))
    try {
        $binary = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
        $executableHash = (Get-FileHash -LiteralPath $executable).Hash
    } catch { $readErrors.Add($_.Exception.Message) }
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $state = $installer.ProductState($ProductCode)
    $registeredVersion = if ($state -eq 5) { $installer.ProductInfo($ProductCode, 'VersionString') } else { $null }
    $keyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MSI:$AppId"
    $values = [ordered]@{}
    if (Test-Path -LiteralPath $keyPath) {
        $key = Get-Item -LiteralPath $keyPath
        foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name) }
    }
    return [ordered]@{
        ObservedAtUtc = [DateTime]::UtcNow.ToString('o')
        PackageVersion = $version; ManifestPath = $manifest; ManifestSha256 = $manifestHash
        ExecutablePath = $executable; BinaryVersion = $(if ($binary.ProductVersion) { $binary.ProductVersion.Split('+')[0] } else { $null }); FileVersion = $binary.FileVersion
        ExecutableSha256 = $executableHash; ReadErrors = @($readErrors.ToArray())
        WindowsInstaller = [ordered]@{ ProductCode = $ProductCode; ProductState = $state; VersionString = $registeredVersion }
        UninstallKey = $keyPath; UninstallValues = $values
        Preservation = Get-ProbePreservation $Data
    }
}

function Assert-MsiRepairEvidence($Result) {
    $before = $Result.PreRepair
    $after = $Result.PostRepair
    $observation = $Result.Observation
    if ($before.PackageVersion -ne '1.0.1' -or $before.BinaryVersion -ne '1.0.1') { throw 'Repair requires package and executable B=1.0.1 before repair.' }
    $expected = if ($Result.Expectation -eq 'CharacterizeRollback') { '1.0.0' } else { '1.0.1' }
    if ($after.PackageVersion -ne $expected -or $after.BinaryVersion -ne $expected) {
        throw "Repair expected package and executable $expected; observed $($after.PackageVersion) / $($after.BinaryVersion)."
    }
    foreach ($snapshot in @($before, $after)) {
        if ($snapshot.ReadErrors.Count -gt 0 -or $snapshot.Preservation.ReadError) { throw 'Repair evidence could not be read completely.' }
        if ($snapshot.WindowsInstaller.ProductState -ne 5 -or -not $snapshot.WindowsInstaller.VersionString -or
            $snapshot.WindowsInstaller.ProductCode -ne $Result.ProductCode) { throw 'Repair lost the probe Windows Installer registration.' }
        if ($snapshot.Preservation.ConsentMode -ne 'installAutomatically' -or $null -ne $snapshot.Preservation.PendingInstallVersion) {
            throw 'Repair did not preserve consent and confirmed update state.'
        }
    }
    foreach ($name in @('config.json', 'diagnostics.log', 'updater.json')) {
        if (-not $before.Preservation.Hashes[$name] -or $before.Preservation.Hashes[$name] -ne $after.Preservation.Hashes[$name]) {
            throw "Repair changed external $name."
        }
    }
    if ($observation.ObservationId -ne $Result.ObservationId -or $observation.Mode -ne 'ObserveOnly' -or
        $observation.PackageVersion -ne $after.PackageVersion -or $observation.BinaryVersion -ne $after.BinaryVersion -or
        $observation.InstallationRoot -ne $Result.Installation -or $observation.ExecutablePath -ne $after.ExecutablePath -or
        $observation.ProcessId -ne $Result.ObservationProcessId) { throw 'Missing, stale, or inconsistent repair process observation.' }
    if ($Result.Expectation -eq 'CharacterizeRollback' -and
        ($before.WindowsInstaller.VersionString -ne '1.0.0.0' -or $after.WindowsInstaller.VersionString -ne '1.0.0.0')) {
        throw 'Windows Installer registration no longer matches the pinned-version characterization.'
    }
}

function Invoke-MsiRepairProbe($Result, $Control, [string]$ControlPath) {
    $Result.PreRepair = Get-MsiRepairSnapshot $Result.Installation $Result.Data $Result.ProductCode $Result.AppId
    if ($Result.PreRepair.PackageVersion -ne '1.0.1' -or $Result.PreRepair.BinaryVersion -ne '1.0.1') {
        throw 'Repair requires package and executable B=1.0.1 before repair.'
    }
    # Configure this BEFORE msiexec: even a launch by repair must only observe and exit.
    $Control.ObserveOnly = $true
    $Control.ObservationId = $Result.ObservationId
    $Control.Feed = $null
    $Control | ConvertTo-Json | Set-Content -LiteralPath $ControlPath
    $observationPath = Join-Path $Result.Data 'repair-observation.json'
    foreach ($path in @($observationPath, "$observationPath.tmp", (Join-Path $Result.Data 'complete'))) {
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    }
    $repairError = $null
    try {
        Invoke-Installer 'msiexec.exe' @('/fa', "`"$($Result.OriginalMsi)`"", '/qn', '/norestart', '/l*v', "`"$($Result.RepairLog)`"") 'MSI original-package repair' $Result.InstallerOperations $Result.RepairLog
    } catch { $repairError = $_ }
    # Capture disk and registration even if msiexec returned a failure/reboot code.
    try { $Result.PostRepair = Get-MsiRepairSnapshot $Result.Installation $Result.Data $Result.ProductCode $Result.AppId } catch {
        $Result.PostRepairError = $_.Exception.Message
        if (-not $repairError) { throw }
    }
    if ($repairError) { throw $repairError }
    if (-not (Test-Path -LiteralPath $Result.RepairLog)) { throw 'MSI repair did not produce its verbose installer log.' }
    # Launch the payload directly: the stable launcher must not apply a cached B package first.
    $process = Start-Process -FilePath $Result.PostRepair.ExecutablePath -WindowStyle Hidden -PassThru
    $Result.ObservationProcessId = $process.Id
    if (-not $process.WaitForExit(15000)) {
        $process.Kill(); $process.WaitForExit()
        throw 'Repair observation process did not exit.'
    }
    $Result.ObservationExitCode = $process.ExitCode
    if ($process.ExitCode -ne 0) { throw "Repair observation failed: $($process.ExitCode)." }
    $Result.Observation = Get-Content -LiteralPath $observationPath -Raw | ConvertFrom-Json
    # Include any changes made during the launch in the preservation check.
    $Result.PostRepair.Preservation = Get-ProbePreservation $Result.Data
    Assert-MsiRepairEvidence $Result
    $Result.Status = if ($Result.Expectation -eq 'CharacterizeRollback') { 'KnownLimitationReproduced' } else { 'UpdatedVersionPreserved' }
    if ($Result.Expectation -eq 'CharacterizeRollback') { Write-Warning 'Known limitation reproduced: original-MSI repair rolled B back to A. This does not establish repair safety.' }
}
