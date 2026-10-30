$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../scripts/MsiRepairProbe.ps1"
# Portable contract tests; these do NOT execute Windows Installer.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('repair-evidence-' + [Guid]::NewGuid().ToString('N'))
$root = $testRoot
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch {
        if ($_.Exception.Message -like "*$Message*") { return }
        throw "Unexpected failure: $($_.Exception.Message); expected $Message"
    }
    throw "Expected failure: $Message"
}
function New-Evidence {
    $before = [ordered]@{
        PackageVersion = '1.0.1'; BinaryVersion = '1.0.1'; ExecutablePath = (Join-Path $testRoot 'current/UpdaterProbe.exe')
        WindowsInstaller = @{ ProductCode = '{probe}'; ProductState = 5; VersionString = '1.0.0.0' }
        Preservation = @{ Hashes = @{ 'config.json' = 'config'; 'diagnostics.log' = 'log'; 'updater.json' = 'prefs' }
            ConsentMode = 'installAutomatically'; PendingInstallVersion = $null }
    }
    $after = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
    $after.PackageVersion = '1.0.0'; $after.BinaryVersion = '1.0.0'
    return [ordered]@{
        AppId = 'SubZeroDev.UpdaterProbe.Smoke.test'; ProductCode = '{probe}'; Data = $testRoot; Installation = $testRoot
        OriginalMsi = (Join-Path $testRoot 'original.msi'); RepairLog = (Join-Path $testRoot 'repair.log')
        InstallerOperations = [Collections.Generic.List[object]]::new()
        ObservationId = [Guid]::NewGuid().ToString('N'); ObservationProcessId = 426
        Expectation = 'CharacterizeRollback'; Status = 'Failed'; PreRepair = $before; PostRepair = $after
        Observation = $null
    }
}
function Set-Observation($Result) {
    $Result.Observation = @{ ObservationId = $Result.ObservationId; Mode = 'ObserveOnly'; ProcessId = 426
        PackageVersion = $Result.PostRepair.PackageVersion; BinaryVersion = $Result.PostRepair.BinaryVersion
        InstallationRoot = $Result.Installation; ExecutablePath = $Result.PostRepair.ExecutablePath }
}
try {
    $evidence = New-Evidence; Set-Observation $evidence
    Assert-MsiRepairEvidence $evidence
    $evidence.Expectation = 'PreserveUpdatedVersion'
    Assert-Throws { Assert-MsiRepairEvidence $evidence } 'expected package and executable 1.0.1'
    $evidence.PostRepair.PackageVersion = '1.0.1'; $evidence.PostRepair.BinaryVersion = '1.0.1'; Set-Observation $evidence
    # Preserving the payload does not assert that MSI inventory was fixed too.
    Assert-MsiRepairEvidence $evidence
    foreach ($mutation in @(
        @{ Apply = { $evidence.PreRepair.BinaryVersion = '1.0.0' }; Error = 'requires package and executable B' },
        @{ Apply = { $evidence.PostRepair.BinaryVersion = '1.0.1' }; Error = 'expected package and executable 1.0.0' },
        @{ Apply = { $evidence.Observation.ObservationId = 'previous-run' }; Error = 'stale' },
        @{ Apply = { $evidence.Observation.ProcessId = 425 }; Error = 'stale' },
        @{ Apply = { $evidence.Observation.ExecutablePath = 'another-app.exe' }; Error = 'stale' },
        @{ Apply = { $evidence.PostRepair.WindowsInstaller.ProductState = -1 }; Error = 'registration' },
        @{ Apply = { $evidence.PostRepair.WindowsInstaller.VersionString = '1.0.1.0' }; Error = 'characterization' },
        @{ Apply = { $evidence.PostRepair.Preservation.ConsentMode = 'ask' }; Error = 'consent' },
        @{ Apply = { $evidence.PostRepair.Preservation.PendingInstallVersion = '1.0.1' }; Error = 'consent' },
        @{ Apply = { $evidence.PostRepair.Preservation.Hashes['config.json'] = 'changed' }; Error = 'changed external config.json' },
        @{ Apply = { $evidence.PostRepair.Preservation.Hashes['diagnostics.log'] = $null }; Error = 'changed external diagnostics.log' },
        @{ Apply = { $evidence.PostRepair.Preservation.Hashes['updater.json'] = 'changed' }; Error = 'changed external updater.json' }
    )) {
        $evidence = New-Evidence; Set-Observation $evidence
        & $mutation.Apply
        Assert-Throws { Assert-MsiRepairEvidence $evidence } $mutation.Error
    }

    # Exercise orchestration with fake OS boundaries: repair error still captures post-repair
    # state; stale completion/observation files are removed; observation must come from this launch.
    function Get-MsiRepairSnapshot {
        $script:snapshotCount++
        if ($script:snapshotCount -eq 1) { return $evidence.PreRepair }
        return $evidence.PostRepair
    }
    function Get-ProbePreservation { return $evidence.PostRepair.Preservation }
    function Start-Process($FilePath, $ArgumentList, [string]$WindowStyle, [switch]$Wait, [switch]$PassThru) {
        if ($FilePath -eq 'msiexec.exe') {
            $control = Get-Content -LiteralPath (Join-Path $testRoot 'control.json') -Raw | ConvertFrom-Json
            if (-not $control.ObserveOnly -or $control.Feed) { throw 'Repair can still update.' }
            if ((Test-Path (Join-Path $testRoot 'complete')) -or (Test-Path (Join-Path $testRoot 'repair-observation.json'))) { throw 'Stale marker survived.' }
            Set-Content -LiteralPath $evidence.RepairLog -Value 'fake installer log'
            return [pscustomobject]@{ ExitCode = $script:installerExitCode }
        }
        if ($script:writeObservation) {
            Set-Observation $evidence
            $evidence.Observation | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'repair-observation.json')
        }
        $process = [pscustomobject]@{ Id = 426; ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $true }
        return $process
    }
    foreach ($exitCode in @(0, 1603, 3010)) {
        $evidence = New-Evidence; $script:snapshotCount = 0; $script:installerExitCode = $exitCode; $script:writeObservation = $true
        Set-Content -LiteralPath (Join-Path $testRoot 'complete') -Value '1.0.1'
        Set-Content -LiteralPath (Join-Path $testRoot 'repair-observation.json') -Value '{"ObservationId":"stale"}'
        $control = @{ Feed = 'B-assets' }
        if ($exitCode -eq 0) {
            Invoke-MsiRepairProbe $evidence $control (Join-Path $testRoot 'control.json') 3>$null
            if ($evidence.Status -ne 'KnownLimitationReproduced') { throw 'Rollback incorrectly classified.' }
        } else {
            Assert-Throws { Invoke-MsiRepairProbe $evidence $control (Join-Path $testRoot 'control.json') } "exit code $exitCode"
        }
        if ($script:snapshotCount -ne 2 -or $evidence.InstallerOperations.Count -ne 1 -or
            $evidence.InstallerOperations[0].ExitCode -ne $exitCode -or -not $evidence.InstallerOperations[0].LogExists) {
            throw 'Missing post-repair state or installer evidence.'
        }
    }
    $evidence = New-Evidence; $script:snapshotCount = 0; $script:installerExitCode = 0; $script:writeObservation = $false
    Assert-Throws { Invoke-MsiRepairProbe $evidence @{ Feed = 'B-assets' } (Join-Path $testRoot 'control.json') } 'does not exist'

    # Load only the case function (never the Windows-only entry point). Verify that an install
    # failure plus a cleanup failure still emits both errors and both installer exit statuses.
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../../scripts/Test-InstalledUpdate.ps1'), [ref]$null, [ref]$null)
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-InstalledUpdate' }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    function Get-MsiProductCode { return '{probe}' }
    function Get-MsiInstalledVersion { return $null }
    function Wait-ProbeExit { }
    $appId = 'SubZeroDev.UpdaterProbe.Smoke.test'; $repo = 'https://github.com/example/probe'
    $update = $testRoot; $runtimePin = '1.2.161'; $cliPin = '1.2.161'; $MsiRepairExpectation = 'CharacterizeRollback'
    $script:installerExitCode = 1603
    Set-Content -LiteralPath $evidence.OriginalMsi -Value 'fake MSI; never executed'
    $previousControl = $env:UPDATER_PROBE_CONTROL
    try {
        Assert-Throws { Test-InstalledUpdate 'MSI' $evidence.OriginalMsi 'public-key' -Repair } 'MSI installation failed with exit code 1603'
        $report = Get-Content -LiteralPath (Join-Path $root 'MSI-Repair/msi-repair.json') -Raw | ConvertFrom-Json
        if ($report.Status -ne 'Failed' -or $report.Error -notlike '*MSI installation*1603*' -or
            $report.CleanupError -notlike '*MSI uninstall*1603*' -or $report.InstallerOperations.Count -ne 2) {
            throw 'Failure report hid the original error or cleanup evidence.'
        }
    } finally { $env:UPDATER_PROBE_CONTROL = $previousControl }
    Write-Output 'MSI repair evidence contract tests passed (mocked OS boundaries; no Windows repair execution).'
} finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }
