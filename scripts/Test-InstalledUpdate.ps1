[CmdletBinding()]
param([string]$OutputDirectory = 'artifacts/installer-smoke', [string]$NuGetConfig)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { throw 'Installer smoke requires Windows.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a fresh smoke output directory.' }

$root = [IO.Path]::GetFullPath($OutputDirectory)
$appId = 'SubZeroDev.UpdaterProbe.Smoke.' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$repo = 'https://github.com/The-Running-Dev/SubZeroDev.UpdaterProbe.Releases'
$baseline = Join-Path $root '1.0.0'
$update = Join-Path $root '1.0.1'
$previousControl = $env:UPDATER_PROBE_CONTROL
$previousSigningKey = $env:UPDATER_PACKAGE_SIGNING_KEY
$signer = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)

function Wait-ForFile([string]$Path, [string]$Description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Description was not created; inspect $root" }
}

function Invoke-Installer([string]$File, [string[]]$Arguments, [string]$Description) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "$Description failed with exit code $($process.ExitCode); inspect $root" }
}

function Test-InstalledUpdate([string]$Kind, [string]$Installer, [string]$SigningKey) {
    $case = Join-Path $root $Kind
    $data = Join-Path $case 'preserved data'
    $installation = Join-Path $case 'installation with spaces'
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $data 'config.json') -Value '{"sentinel":"preserve-config"}'
    Set-Content -LiteralPath (Join-Path $data 'diagnostics.log') -Value 'preserve-log'
    $env:UPDATER_PROBE_CONTROL = Join-Path $data 'control.json'
    $control = @{ AppId = $appId; Repository = $repo; Data = $data; Target = '1.0.0'; Feed = (Join-Path $update 'assets'); SigningKey = $SigningKey }
    $control | ConvertTo-Json | Set-Content -LiteralPath $env:UPDATER_PROBE_CONTROL
    $installed = $false
    try {
        if ($Kind -eq 'Setup') {
            Invoke-Installer $Installer @('--silent', '--installto', "`"$installation`"") 'Setup installation'
        } else {
            $log = Join-Path $case 'msi-install.log'
            Invoke-Installer 'msiexec.exe' @('/i', "`"$Installer`"", '/qn', '/norestart', "VELOPACK_INSTALLDIR=`"$installation`"", '/l*v', "`"$log`"") 'MSI installation'
        }
        $installed = $true
        $launcher = Join-Path $installation "$appId.exe"
        Wait-ForFile $launcher "$Kind launcher"

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
        }
        Write-Output "$Kind A -> B passed: $data"
    } finally {
        if ($installed) {
            if ($Kind -eq 'Setup') {
                $uninstaller = Join-Path $installation 'Update.exe'
                Invoke-Installer $uninstaller @('--silent', 'uninstall') 'Setup uninstall'
            } else {
                $log = Join-Path $case 'msi-uninstall.log'
                Invoke-Installer 'msiexec.exe' @('/x', "`"$Installer`"", '/qn', '/norestart', '/l*v', "`"$log`"") 'MSI uninstall'
                # Velopack 1.2.161 leaves its version-only HKCU key after msiexec removes an updated MSI.
                # This key belongs to the randomly generated smoke app, so remove it without touching other installs.
                $versionKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MSI:$appId"
                if (Test-Path -LiteralPath $versionKey) {
                    Write-Warning "MSI uninstall left the Velopack version key for $appId; removing the smoke-test key."
                    Remove-Item -LiteralPath $versionKey
                }
            }
            if (Test-Path -LiteralPath $installation) { throw "$Kind uninstall left its installation directory: $installation" }
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
} finally {
    $env:UPDATER_PROBE_CONTROL = $previousControl
    $env:UPDATER_PACKAGE_SIGNING_KEY = $previousSigningKey
    $signer.Dispose()
}
