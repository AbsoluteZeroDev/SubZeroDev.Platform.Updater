[CmdletBinding()]
param(
    [string]$OutputDirectory = 'artifacts/installer-smoke', [string]$NuGetConfig, [switch]$RequireCleanMsiUninstall,
    [ValidateSet('CharacterizeRollback', 'PreserveUpdatedVersion')][string]$MsiRepairExpectation = 'CharacterizeRollback'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { throw 'Installer smoke requires Windows.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a fresh smoke output directory.' }
. "$PSScriptRoot/MsiRepairProbe.ps1"

$root = [IO.Path]::GetFullPath($OutputDirectory)
$appId = 'SubZeroDev.UpdaterProbe.Smoke.' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$repo = 'https://github.com/The-Running-Dev/SubZeroDev.UpdaterProbe.Releases'
$baseline = Join-Path $root '1.0.0'
$update = Join-Path $root '1.0.1'
$previousControl = $env:UPDATER_PROBE_CONTROL
$previousSigningKey = $env:UPDATER_PACKAGE_SIGNING_KEY
$signer = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
$runtimePin = ([xml](Get-Content -LiteralPath "$PSScriptRoot/../Directory.Packages.props" -Raw)).Project.ItemGroup.PackageVersion.Where({ $_.Include -eq 'Velopack' }).Version
$cliPin = (Get-Content -LiteralPath "$PSScriptRoot/../.config/dotnet-tools.json" -Raw | ConvertFrom-Json).tools.vpk.version

function Wait-ForFile([string]$Path, [string]$Description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Description was not created; inspect $root" }
}

function Get-MsiProductCode([string]$Path) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Path, 0)
    $view = $database.OpenView("SELECT Value FROM Property WHERE Property = 'ProductCode'")
    $null = $view.Execute()
    $record = $view.Fetch()
    if ($null -eq $record) { throw "MSI has no ProductCode: $Path" }
    return $record.StringData(1)
}

function Get-MsiInstalledVersion([string]$ProductCode) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    if ($installer.ProductState($ProductCode) -ne 5) { return $null }
    return $installer.ProductInfo($ProductCode, 'VersionString')
}

function Get-ProbeShortcuts([string]$AppId) {
    $roots = @([Environment]::GetFolderPath('StartMenu'), [Environment]::GetFolderPath('DesktopDirectory'))
    return @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter "$AppId*.lnk" -ErrorAction SilentlyContinue } |
        Select-Object -ExpandProperty FullName -Unique)
}

function Test-InstalledUpdate([string]$Kind, [string]$Installer, [string]$SigningKey, [switch]$Repair) {
    $caseName = if ($Repair) { 'MSI-Repair' } else { $Kind }
    $case = Join-Path $root $caseName
    $data = Join-Path $case 'preserved data'
    $installation = Join-Path $case 'installation with spaces'
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $data 'config.json') -Value '{"sentinel":"preserve-config"}'
    Set-Content -LiteralPath (Join-Path $data 'diagnostics.log') -Value 'preserve-log'
    $env:UPDATER_PROBE_CONTROL = Join-Path $data 'control.json'
    $control = @{ AppId = $appId; Repository = $repo; Data = $data; Target = '1.0.0'; Feed = (Join-Path $update 'assets'); SigningKey = $SigningKey }
    $control | ConvertTo-Json | Set-Content -LiteralPath $env:UPDATER_PROBE_CONTROL
    $installed = $false
    $productCode = if ($Kind -eq 'MSI') { Get-MsiProductCode $Installer } else { $null }
    $msiLifecycle = if ($Kind -eq 'MSI') { [ordered]@{ ProductCode = $productCode; InitialInstallerVersion = '1.0.0'; UpdatedPackageVersion = '1.0.1' } } else { $null }
    $repairResult = if ($Repair) { [ordered]@{
        SchemaVersion = 1; AppId = $appId; ProductCode = $productCode; Installation = $installation; Data = $data
        OriginalMsi = $Installer; OriginalMsiSha256 = (Get-FileHash -LiteralPath $Installer).Hash
        VelopackRuntime = $runtimePin; VelopackCli = $cliPin
        OS = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        ProcessArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        Expectation = $MsiRepairExpectation; Status = 'Failed'; Error = $null; CleanupError = $null
        ExpectedPostRepairVersion = $(if ($MsiRepairExpectation -eq 'CharacterizeRollback') { '1.0.0' } else { '1.0.1' })
        ObservationId = [Guid]::NewGuid().ToString('N'); RepairLog = (Join-Path $case 'msi-repair.log')
        InstallerOperations = [Collections.Generic.List[object]]::new()
        PreRepair = $null; PostRepair = $null; Observation = $null; Cleanup = $null
    } } else { $null }
    $operations = $null
    if ($Repair) { $operations = $repairResult.InstallerOperations }
    try {
        if ($Repair -and $null -ne (Get-MsiInstalledVersion $productCode)) { throw 'Previous probe MSI is still registered; refusing to reuse it for repair.' }
        if ($Kind -eq 'Setup') {
            Invoke-Installer $Installer @('--silent', '--installto', "`"$installation`"") 'Setup installation'
        } else {
            $log = Join-Path $case 'msi-install.log'
            $installed = $true # Also attempt scoped cleanup after a partial installation failure.
            Invoke-Installer 'msiexec.exe' @('/i', "`"$Installer`"", '/qn', '/norestart', "VELOPACK_INSTALLDIR=`"$installation`"", '/l*v', "`"$log`"") 'MSI installation' $operations $log
        }
        $installed = $true
        $launcher = Join-Path $installation "$appId.exe"
        Wait-ForFile $launcher "$Kind launcher"
        if ($Kind -eq 'MSI') {
            $msiLifecycle.InstalledProductVersion = Get-MsiInstalledVersion $productCode
            if ([Version]::Parse($msiLifecycle.InstalledProductVersion).ToString(3) -ne '1.0.0') { throw "Windows Installer registered $($msiLifecycle.InstalledProductVersion), expected 1.0.0." }
            $msiLifecycle.InstalledShortcuts = @(Get-ProbeShortcuts $appId)
        }

        $control.Target = '1.0.1'
        $control | ConvertTo-Json | Set-Content -LiteralPath $env:UPDATER_PROBE_CONTROL
        Remove-Item -LiteralPath (Join-Path $data 'complete') -ErrorAction SilentlyContinue
        $process = Start-Process -FilePath $launcher -WindowStyle Hidden -PassThru
        $complete = Join-Path $data 'complete'
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        do {
            Start-Sleep -Milliseconds 250
            $completedVersion = if (Test-Path -LiteralPath $complete) { (Get-Content -LiteralPath $complete -Raw).Trim() } else { '' }
        } while ($completedVersion -ne '1.0.1' -and [DateTime]::UtcNow -lt $deadline)
        if ($completedVersion -ne '1.0.1') { throw "$Kind update did not relaunch; inspect $data" }
        if (-not $process.WaitForExit(5000)) { throw "$Kind old process did not exit." }

        $runs = @(Get-Content -LiteralPath (Join-Path $data 'runs.log'))
        if ($runs.Count -ne 2) { throw "$Kind expected one launch and one relaunch; found $($runs.Count)." }
        foreach ($i in 0..1) {
            $expected = @('1.0.0', '1.0.1')[$i]
            $fields = $runs[$i].Split('|')
            if ($fields[0] -ne $expected -or $fields[1] -ne $expected) { throw "$Kind run $($i + 1) expected package and binary $expected; found $($fields[0]) / $($fields[1])." }
            if ($fields[3] -ne $installation) { throw "$Kind run $($i + 1) used the wrong installation root: $($fields[3])." }
        }
        if ((Get-Content -LiteralPath (Join-Path $data 'config.json') -Raw) -notmatch 'preserve-config' -or
            (Get-Content -LiteralPath (Join-Path $data 'diagnostics.log') -Raw) -notmatch 'preserve-log') { throw "$Kind replaced application data." }
        $prefs = Get-Content -LiteralPath (Join-Path $data 'updater.json') -Raw | ConvertFrom-Json
        if ($prefs.consentMode -ne 'installAutomatically' -or $null -ne $prefs.pendingInstallVersion) { throw "$Kind did not retain consent or confirm the installed update." }
        if ($Kind -eq 'MSI') {
            $entry = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MSI:$appId" -ErrorAction Stop
            if ($entry.DisplayVersion -ne '1.0.1') { throw "MSI uninstall registration has version $($entry.DisplayVersion), expected 1.0.1." }
            $msiLifecycle.UpdatedProductVersion = Get-MsiInstalledVersion $productCode
            $msiLifecycle.UpdatedUninstallVersion = $entry.DisplayVersion
            $registeredVersion = [Version]::Parse($msiLifecycle.UpdatedProductVersion).ToString(3)
            if ($registeredVersion -notin @('1.0.0', '1.0.1')) { throw "Windows Installer registered unexpected version $($msiLifecycle.UpdatedProductVersion) after update." }
            $msiLifecycle.UpdatedShortcuts = @(Get-ProbeShortcuts $appId)
            if ($registeredVersion -ne '1.0.1') {
                Write-Warning "Windows Installer still registers $($msiLifecycle.UpdatedProductVersion) after the Velopack update to 1.0.1."
            }
        }
        if ($Repair) {
            $repairResult.UpdateRuns = $runs
            Wait-ProbeExit $installation
            Invoke-MsiRepairProbe $repairResult $control $env:UPDATER_PROBE_CONTROL
        }
        Write-Output "$caseName A -> B validation completed: $data"
    } catch {
        if ($Repair) { $repairResult.Error = $_.Exception.Message }
        throw
    } finally {
      try {
        if ($installed) {
            Wait-ProbeExit $installation
            if ($Kind -eq 'Setup') {
                $uninstaller = Join-Path $installation 'Update.exe'
                Invoke-Installer $uninstaller @('--silent', 'uninstall') 'Setup uninstall'
            } else {
                $log = Join-Path $case 'msi-uninstall.log'
                Invoke-Installer 'msiexec.exe' @('/x', "`"$Installer`"", '/qn', '/norestart', '/l*v', "`"$log`"") 'MSI uninstall' $operations $log
                $msiLifecycle.UninstalledProductVersion = Get-MsiInstalledVersion $productCode
                if ($null -ne $msiLifecycle.UninstalledProductVersion) { throw "MSI uninstall left Windows Installer product $productCode registered." }
                # Velopack 1.2.161 leaves its version-only HKCU key after msiexec removes an updated MSI.
                # Capture its exact contents before removing only this randomly generated smoke app's key.
                $versionKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MSI:$appId"
                $residue = @()
                if (Test-Path -LiteralPath $versionKey) {
                    $residue = @((Get-Item -LiteralPath $versionKey).GetValueNames() | Sort-Object)
                    Write-Warning "MSI uninstall left the Velopack version key for $appId with values: $($residue -join ', '); removing the smoke-test key."
                    Remove-Item -LiteralPath $versionKey
                }
                $msiLifecycle.ResidualUninstallValues = $residue
                $shortcuts = @(Get-ProbeShortcuts $appId)
                $msiLifecycle.ResidualShortcuts = $shortcuts
                if ($Repair) { $repairResult.Cleanup = $msiLifecycle }
                $msiLifecycle | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $case 'msi-lifecycle.json')
                if ($residue.Count -gt 0 -and ($residue.Count -ne 1 -or $residue[0] -ne 'DisplayVersion')) { throw "MSI uninstall left unexpected registry values: $($residue -join ', ')." }
                if ($RequireCleanMsiUninstall -and $residue.Count -gt 0) { throw "MSI uninstall left the Velopack version key; a clean uninstall is required." }
                if ($shortcuts.Count -gt 0) { throw "MSI uninstall left shortcuts: $($shortcuts -join ', ')." }
            }
            if (Test-Path -LiteralPath $installation) { throw "$Kind uninstall left its installation directory: $installation" }
        }
      } catch {
        if (-not $Repair) { throw }
        $repairResult.CleanupError = $_.Exception.Message
        $repairResult.Status = 'Failed'
        if (-not $repairResult.Error) { throw }
      } finally {
        if ($Repair) {
            $repairResult.CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
            $repairResult | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $case 'msi-repair.json')
        }
      }
    }
}

try {
    $env:UPDATER_PACKAGE_SIGNING_KEY = $signer.ExportPkcs8PrivateKeyPem()
    $packArguments = @{}
    if ($NuGetConfig) { $packArguments.NuGetConfig = $NuGetConfig }
    foreach ($version in @('1.0.0', '1.0.1')) {
        $destination = if ($version -eq '1.0.0') { $baseline } else { $update }
        & "$PSScriptRoot/Pack-Application.ps1" -Project tests/UpdaterProbe/UpdaterProbe.csproj -AppId $appId -MainExe UpdaterProbe.exe -Version $version -ReleaseNotes README.md -OutputDirectory $destination @packArguments
        if (-not (Get-ChildItem (Join-Path $destination 'assets') -Filter '*-full.nupkg.sig')) { throw "Release $version was not signed." }
    }
    $assets = Join-Path $baseline 'assets'
    $publicKey = $signer.ExportSubjectPublicKeyInfoPem()
    Test-InstalledUpdate 'Setup' (Get-ChildItem $assets -Filter '*-Setup.exe').FullName $publicKey
    Test-InstalledUpdate 'MSI' (Get-ChildItem $assets -Filter '*.msi').FullName $publicKey
    # Independent fresh install: retain the ordinary B -> uninstall path above.
    Test-InstalledUpdate 'MSI' (Get-ChildItem $assets -Filter '*.msi').FullName $publicKey -Repair
} finally {
    $env:UPDATER_PROBE_CONTROL = $previousControl
    $env:UPDATER_PACKAGE_SIGNING_KEY = $previousSigningKey
    $signer.Dispose()
}
