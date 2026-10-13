# Without arguments, as a pre-build step of the shared .NET workflow, it checks the run's ref.
param(
    [string]$Ref = $env:GITHUB_REF,
    [string]$DefaultBranch = $(if ($env:GITHUB_EVENT_PATH) { (Get-Content -Raw $env:GITHUB_EVENT_PATH | ConvertFrom-Json).repository.default_branch })
)
$ErrorActionPreference = 'Stop'
if (-not $Ref -or -not $DefaultBranch) { throw 'Pass -Ref and -DefaultBranch outside GitHub Actions.' }
if (-not $Ref.StartsWith('refs/tags/', [StringComparison]::Ordinal)) { throw 'Publication requires a tag ref.' }
git check-ref-format $Ref
if ($LASTEXITCODE) { throw 'Invalid tag ref.' }
$branchRef = "refs/heads/$DefaultBranch"
git check-ref-format $branchRef
if ($LASTEXITCODE) { throw 'Invalid default branch.' }
git fetch --no-tags origin "+${branchRef}:refs/remotes/origin/$DefaultBranch"
if ($LASTEXITCODE) { throw 'Could not fetch the default branch.' }
$commit = git rev-parse --verify "$Ref^{commit}"
if ($LASTEXITCODE) { throw 'The tag does not identify a commit.' }
$headCommit = git rev-parse --verify HEAD
if ($LASTEXITCODE -or $headCommit -ne $commit) { throw 'The checkout does not match the release tag.' }
git merge-base --is-ancestor $commit "refs/remotes/origin/$DefaultBranch"
if ($LASTEXITCODE) { throw 'The tagged commit is not reachable from the default branch.' }
