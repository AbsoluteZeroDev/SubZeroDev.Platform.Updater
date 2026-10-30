# Windows validation

Validated with .NET 10, Velopack runtime/CLI 1.2.161, Windows x64. MSI lifecycle was revalidated on 2026-10-27. Artifacts are unsigned.
Local evidence is retained under ignored `artifacts/`; CI repeats deterministic, portable, Setup, and MSI gates.
The original-MSI repair automation described below was added after the October 27 manual reproduction. Its implementation and portable checks are separate from completed Windows repair executions.

| Gate | Evidence |
|---|---|
| Library | 32 deterministic tests: defaults/atomic storage, corrupt/locked preferences and bounded transient-lock recovery, manual override, throttling failures, cancellation/single-flight, exact-candidate consent, deferral, restart, unsupported layout, HTTP errors, feed identity, semantic channel selection, SHA-256 tampering. |
| Real NuGet consumers | WPF and WinUI 3 restore 0.1.0 from a freshly packed feed with an empty cache; both Release builds pass. Both executables ran a manual check and reported UnsupportedInstallation, correctly identifying their unpackaged layout. |
| Portable | Real packaged probe A=1.0.0 → B=1.0.1 → C=1.0.2, each version a separate publish, one process relaunch per update, root launcher in a path with spaces. Each run's compiled binary version must equal its package version, and the relaunched process must confirm the recorded pending install. External config/log sentinels and persisted consent survive. `scripts/Test-PortableUpdate.ps1` repeats this and runs in CI. The probe serves each version's output through a fake GitHub (release listing, redirected downloads), so the production release source runs rather than a file-source shortcut. Since 2026-10-02 every version is signed with an ephemeral publisher key whose public half the probe pins, so each update also passes package signature verification. |
| Setup | `scripts/Test-InstalledUpdate.ps1` runs a silent per-user Setup A→B update in a path with spaces. It verifies the relaunched binary, pinned publisher signature, preserved external data and consent, and uninstall cleanup. CI repeats this gate. The earlier manual A→B→C run is retained as local evidence under `setup-data`. |
| MSI | The same script runs a per-user MSI A→B update without elevation and verifies the relaunched binary, pinned publisher signature, preserved data, Windows Installer product version, custom HKCU uninstall version, shortcut cleanup, and product unregistration. CI repeats this gate. `MSI/msi-lifecycle.json` records the observed versions and residual key values. On Velopack 1.2.161, Windows Installer reported 1.0.0.0 after the app reached 1.0.1, and `msiexec /x` left a `DisplayVersion`-only HKCU key; the script removes only its uniquely named smoke-test key. A separate local `msiexec /fa` probe with the original MSI restored `current/sq.version` from 1.0.1 to 1.0.0. The cleanup fix is merged upstream but not in this pinned release; use `-RequireCleanMsiUninstall` when testing a newer Velopack. Evidence: `artifacts/msi-lifecycle-local-3`. The earlier manual run is retained under `msi-data`. |
| Public GitHub | Public probe v1.0.1 contains ZIP, Setup, MSI, full nupkg, feed, SHA256SUMS and notes. Packaged A checked/downloaded/verified/applied/relaunched B through the production unauthenticated GitHub source. Evidence: github-data. |
| MSI original-package repair | `Test-InstalledUpdate.ps1` now also runs an independent fresh MSI A→B→original-MSI repair→uninstall case, after the ordinary B→uninstall case. It writes `MSI-Repair/msi-repair.json` and verbose installer logs. The default characterizes the known rollback on 1.2.161; `-MsiRepairExpectation PreserveUpdatedVersion` instead requires B to survive. Adding the gate does not constitute a new Windows repair execution; see commands and evidence contract below. |
| HotCorners | Actual packaged 1.1.0→1.1.1 local-feed update completed; `current/sq.version` became 1.1.1 and a new app process ran from the same stable root. Isolated updater preferences and preservation sentinel survived. Smoke-only build enables the local feed and isolated settings; production builds exclude those hooks. |
| HotCorners regression | 214 tests pass: 66 Core, 74 Platform, 74 App. Includes startup migration/quoting, native menu checked/radio/busy states, and safe restart waiting for an occupied action slot. |

Public probe: https://github.com/The-Running-Dev/SubZeroDev.UpdaterProbe.Releases/releases/tag/v1.0.1

## Reproduction

Run `scripts/Test-Package.ps1`. Pack probe A with `scripts/Pack-Application.ps1`, AppId
`SubZeroDev.UpdaterProbe`, MainExe `UpdaterProbe.exe`, version `1.0.0`, output `artifacts/probe`.
Run `scripts/Test-PortableUpdate.ps1` and `scripts/Test-InstalledUpdate.ps1`. Use fresh output directories on each run.

For Setup, run its generated installer with `--silent --installto <writable-path>`; for MSI use
`msiexec /i <generated-msi> /qn /norestart /l*v <log>`. Before launching either stable root EXE,
set UPDATER_PROBE_CONTROL to an external JSON file containing AppId, Repository, Data, Target
and Feed, plus an optional SigningKey (the publisher public key to pin). Point Feed at B/C assets for local tests; use null for the public GitHub test. The
probe's `runs.log`, `states.log`, `complete`, and `updater.json` record the actual result.
Uninstall the same AppId's Setup before installing MSI. Preserve test evidence outside install roots.

Sample runtime checks: set UPDATER_SAMPLE_SMOKE to an absolute result-file path, run either
built sample EXE and wait for its normal exit. The UI dispatcher runs the manual check and
writes its outcome. Clear that variable for interactive use.

### Original-MSI repair characterization

From the repository root on Windows x64 with PowerShell 7 and .NET 10, run:

```powershell
pwsh -NoProfile -File scripts/Test-InstalledUpdate.ps1 -OutputDirectory artifacts/msi-repair-characterization -MsiRepairExpectation CharacterizeRollback
```

Use a fresh output directory each time. The script builds the existing isolated, randomly named
`SubZeroDev.UpdaterProbe.Smoke.*` application and signed A=1.0.0 / B=1.0.1 packages with the
unchanged runtime/CLI 1.2.161 pins. It first runs the ordinary Setup and MSI update/uninstall
cases. It then reinstalls the same probe's original A MSI in a separate `MSI-Repair` installation,
applies the signed B update, waits for the probe processes to exit, and invokes:

```powershell
msiexec.exe /fa "<original-1.0.0.msi>" /qn /norestart /l*v "<output>/MSI-Repair/msi-repair.log"
```

Before repair, control is switched to `ObserveOnly` with no feed and a fresh observation nonce.
The old `complete` and repair observation files are removed. After repair, the script snapshots
the files on disk and launches `current/UpdaterProbe.exe` directly. The probe disables Velopack
startup auto-apply and returns before constructing an updater client in observation mode, so
neither a cached package nor another update check can hide the repaired payload. The new process
must exit successfully and report the expected nonce, process ID, executable path, installation
root, package version, and compiled version. The earlier A→B completion marker is never accepted
as repair evidence.

`<output>/MSI-Repair/msi-repair.json` records:

| Evidence | Fields |
|---|---|
| Identity and expectation | Probe AppId, ProductCode, isolated installation/data paths, original MSI path and SHA-256, runtime/CLI pins, OS/architecture, expectation and expected version. |
| Before and after repair | `PreRepair` / `PostRepair`: `sq.version` package version and hash, executable product/file versions and hash, Windows Installer product state/version, and custom HKCU uninstall key values. |
| Installer outcome | `InstallerOperations`: exact argument arrays, start/end timestamps, exit codes/errors, and verbose install/repair/uninstall log paths and existence. Only exit 0 passes; reboot-required codes remain visible and fail immediate validation. |
| Process observation | `ObservationId`, launched process ID/exit code, and `Observation` from the repaired binary, independent of `complete`. |
| External preservation | Pre/post SHA-256 hashes for config, diagnostics, and updater preferences; persisted automatic consent and no pending install. The observation must leave all three files byte-for-byte unchanged. |
| Cleanup and failures | Product unregistration, shortcut and key residue evidence, primary error and separate cleanup error. The result is written in `finally`, including after repair or cleanup failure. |

On the pinned version, `CharacterizeRollback` expects package **and executable** 1.0.0 after
repair, with Windows Installer still registering 1.0.0.0 before and after. Its passing status is
`KnownLimitationReproduced`: it establishes the limitation, **not repair safety or an upstream
fix**. An unexpected result fails and retains the evidence rather than being silently accepted.
The October 27 manual execution established the `sq.version` rollback; the new gate additionally
requires the executable and fresh process evidence.

For a future fix, explicitly require preservation of B (this task does not upgrade Velopack):

```powershell
pwsh -NoProfile -File scripts/Test-InstalledUpdate.ps1 -OutputDirectory artifacts/msi-repair-preserved -MsiRepairExpectation PreserveUpdatedVersion
```

This expectation fails on a rollback and reports `UpdatedVersionPreserved` only when both package
and executable remain 1.0.1, the fresh process agrees, registration remains present, and external
data/consent survive. MSI inventory versions are still recorded; payload preservation alone does
not establish that inventory reconciliation or every repair behavior is fixed.
`-RequireCleanMsiUninstall` is an independent assertion for the separate upstream uninstall-key
cleanup fix and can be combined with either command. Cleanup uses only the generated probe MSI,
its exact uninstall key, and its isolated paths; it never repairs a production application.

Portable evidence-contract checks (mocked OS boundaries, no MSI execution):

```powershell
pwsh -NoProfile -File tests/UpdaterProbe/Test-MsiRepairEvidence.ps1
```

These cover rollback/preservation expectations, inconsistent versions, stale observations, data
or consent changes, registration loss, installer failures/reboot codes, and result persistence
when installation and cleanup both fail. `Test-Distribution.ps1` runs them before packaging and
runs all three installed cases through the existing Windows CI entry point.
It also prints the repair JSON in the CI job log, including after failure.

### CI diagnostic artifacts

The distribution entry point now stages an allowlisted bundle under `artifacts/probe-evidence`
in `finally`, including after a probe or packaging failure. CI and the NuGet workflow opt into
the shared .NET workflow's separate `updater-probe-evidence-windows-latest` artifact. Retention
is explicitly **7 days**. The test-result artifact remains separate.

| Bundle path | Contents |
|---|---|
| `MSI/msi-lifecycle.json` | Normal MSI update/uninstall report, when produced. |
| `MSI/msi-install.log`, `MSI/msi-uninstall.log` | Normal MSI verbose installer logs. |
| `MSI-Repair/msi-repair.json` | Repair report, including partial failure and cleanup evidence from #20. |
| `MSI-Repair/msi-install.log`, `MSI-Repair/msi-repair.log`, `MSI-Repair/msi-uninstall.log` | Repair case verbose installer logs, when each operation ran. |
| `MSI-Repair/preserved data/repair-observation.json` | Fresh process observation, when produced. |
| `bundle-manifest.json` | Collected relative paths and SHA-256 hashes, missing paths and collection failures. |

Only these exact filenames are copied. No recursive smoke-tree upload is used. In particular,
`control.json` (which includes `SigningKey`), signing material, package assets, installations,
preferences, sentinel data and unrelated files are excluded. Symbolic links and junctions in
source paths are rejected. The ephemeral private signing key is removed from the environment
after packaging, before verbose installer processes run; the caller's original environment is
restored in the existing cleanup. Staging is reset before each distribution attempt; an existing smoke
source is rejected rather than collected as fresh evidence.

Collection runs even when the distribution probe throws. Missing files are expected on partial
runs and recorded in the manifest; available files are still retained. Collection errors fail an
otherwise successful run, but are warnings alongside an existing probe failure so they cannot
replace it. The shared upload runs after failure independently of TRX output, unless cancelled.
Runner loss, cancellation or an upload-service failure can still prevent an artifact.

```powershell
pwsh -NoProfile -File tests/UpdaterProbe/Test-ProbeEvidence.ps1
```

These portable checks cover full/partial/early-failure collection, exclusion of control and
package data, stale evidence, link rejection and primary/secondary failure handling. They do
not run MSI or prove a GitHub upload. The prior characterization run
[`40758208014`](https://github.com/The-Running-Dev/SubZeroDev.Platform.Updater/actions/runs/40758208014)
uploaded only test results; this collection cannot recover that completed runner's unuploaded
logs. A new CI artifact must be inspected separately before claiming an observed upload.

The caller pins the full shared-template implementation commit, as permitted by its versioning
rules, because the existing `v1` tag does not yet declare these new inputs. A future release may
replace that pin once it contains them. This changes CI evidence only: production installers,
the 1.2.161 Velopack pins, and rollback characterization expectations remain unchanged.

## Publication gates still requiring the owner

- Configure NuGet trusted publishing (nuget.org policy, `nuget` environment, `NUGET_USER`; see release-guide.md), then push the `v0.1.0` tag to publish.
- Configure HOTCORNERS_RELEASE_TOKEN for CI Contents write to the public binary repository.
- Configure a signing identity if signed distributions are required. These tests establish update
  mechanics and integrity validation; they do not establish Authenticode trust or SmartScreen reputation.

The first product release is v1.1.0. Its workflow requires the published NuGet package before
publishing binaries. The existing v1.0.0 release is untouched. Private-source CI can temporarily
restore an actual local NuGet built from a pinned public updater commit; that bootstrap does not
claim nuget.org publication. No paid package or external credential is assumed. The library is MIT licensed.
