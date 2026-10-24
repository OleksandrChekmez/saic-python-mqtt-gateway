<#
.SYNOPSIS
Updates the fork from the newest upstream release and publishes it to Home Assistant.

.DESCRIPTION
1. Merges the newest upstream release tag (including release candidates) into `custom`.
2. Runs ruff, mypy and pytest.
3. Pushes `custom` and a `<X.Y.Z>-oc<N>` tag, which builds the custom image on GitHub.
4. Waits for the image build to succeed.
5. Merges upstream into the add-on fork, sets its version to the new tag and pushes it.

Every step can be repeated. If the script stops (merge conflict, failing test, failed
build), fix the problem and run it again: it continues where it left off.

.PARAMETER Tag
Upstream release tag to update to, for example 0.14.0. Defaults to the newest one.

.PARAMETER DryRun
Shows what would happen. Fetches from the remotes but changes nothing else.

.PARAMETER Yes
Does not ask for confirmation before pushing.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\update-fork.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [switch]$DryRun,
    [switch]$Yes,
    [string]$GatewayRepo,
    [string]$AddonRepo,
    [int]$BuildTimeoutMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $GatewayRepo) {
    $GatewayRepo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
if (-not $AddonRepo) {
    $AddonRepo = Join-Path (Split-Path -Parent $GatewayRepo) 'saic-home-assistant-addon'
}

$Branch = 'custom'
$BuildWorkflow = 'build_custom_images.yml'
$AddonConfig = 'saic-python-mqtt-gateway/config.yaml'
$ReleasePattern = '^(\d+)\.(\d+)\.(\d+)(?:-rc(\d+))?$'

# --- Output helpers -------------------------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info([string]$Message) { Write-Host "    $Message" }

function Write-Warn([string]$Message) { Write-Host "    WARNING: $Message" -ForegroundColor Yellow }

function Stop-Script([string]$Message) {
    Write-Host ''
    Write-Host "STOPPED: $Message" -ForegroundColor Red
    exit 1
}

# --- Git helpers ----------------------------------------------------------------------

# Runs git in a repository and returns its output. Stops the script if git fails.
function Invoke-Git([string]$Repo, [string[]]$GitArgs, [switch]$AllowFailure) {
    $output = & git -C $Repo @GitArgs
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        Stop-Script "git $($GitArgs -join ' ') failed in $Repo"
    }
    return $output
}

# Runs git and returns $true when it exits with 0.
function Test-Git([string]$Repo, [string[]]$GitArgs) {
    & git -C $Repo @GitArgs | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-CommitId([string]$Repo, [string]$Rev) {
    return [string](Invoke-Git $Repo @('rev-parse', '--verify', '--quiet', "$Rev^{commit}") -AllowFailure)
}

function Test-MergeInProgress([string]$Repo) {
    return (Test-Git $Repo @('rev-parse', '--verify', '--quiet', 'MERGE_HEAD'))
}

function Get-AheadCount([string]$Repo, [string]$From, [string]$To) {
    return [int](Invoke-Git $Repo @('rev-list', '--count', "$From..$To"))
}

# Checks the branch, unfinished merges and uncommitted changes to tracked files.
function Assert-Ready([string]$Repo, [string[]]$AllowedChanges = @()) {
    if (-not (Test-Path (Join-Path $Repo '.git'))) { Stop-Script "$Repo is not a git repository." }

    $current = [string](Invoke-Git $Repo @('rev-parse', '--abbrev-ref', 'HEAD'))
    if ($current -ne $Branch) { Stop-Script "$Repo is on '$current'. Switch to '$Branch' first." }

    if (Test-MergeInProgress $Repo) {
        Stop-Script ("A merge is in progress in $Repo. Fix the conflicts, run " +
            "'git add <files>' and 'git commit --no-edit', then run this script again.")
    }

    $dirty = @(Invoke-Git $Repo @('status', '--porcelain', '--untracked-files=no') |
        Where-Object { $_ -and ($AllowedChanges -notcontains $_.Substring(3)) })
    if ($dirty.Count -gt 0) {
        Stop-Script "$Repo has uncommitted changes:`n$($dirty -join "`n")"
    }
}

# Lists the conflicting files a merge would produce, without touching the working tree.
function Get-MergeConflicts([string]$Repo, [string]$Ours, [string]$Theirs) {
    $lines = @(Invoke-Git $Repo @('merge-tree', '--write-tree', '--name-only', $Ours, $Theirs) -AllowFailure)
    if ($LASTEXITCODE -eq 0) { return @() }
    $files = @()
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if (-not $line) { break }
        $files += $line
    }
    return $files
}

# --- Release helpers ------------------------------------------------------------------

# Sorts 0.14.0-rc1 < 0.14.0-rc2 < 0.14.0 < 0.14.1-rc1.
function Get-ReleaseSortKey([string]$Name) {
    $m = [regex]::Match($Name, $ReleasePattern)
    $rc = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { 99999 }
    return '{0:D5}.{1:D5}.{2:D5}.{3:D5}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value,
        [int]$m.Groups[3].Value, $rc
}

function Get-RemoteTagNames([string]$Repo, [string]$Remote) {
    foreach ($line in @(Invoke-Git $Repo @('ls-remote', '--tags', '--refs', $Remote))) {
        if ($line) { ($line -split "`t")[1] -replace '^refs/tags/', '' }
    }
}

# Environment variables the gateway reads at a given commit.
function Get-GatewayEnvVars([string]$Rev) {
    $found = @(Invoke-Git $GatewayRepo @('grep', '-h', '-o', '-E', 'envvar=.[A-Z0-9_]+', $Rev, '--', 'src/configuration') -AllowFailure)
    return @($found | Where-Object { $_ } | ForEach-Object { $_ -replace '^envvar=.', '' } | Sort-Object -Unique)
}

function Get-AddonVersion {
    $text = [IO.File]::ReadAllText((Join-Path $AddonRepo $AddonConfig))
    $m = [regex]::Match($text, '(?m)^version:\s*"?([^"\r\n]+)"?')
    if (-not $m.Success) { Stop-Script "No version line found in $AddonConfig." }
    return $m.Groups[1].Value.Trim()
}

# Sets the add-on version. A conflict on the version line alone is resolved here;
# any other conflict stops the script.
function Set-AddonVersion([string]$Version) {
    $path = Join-Path $AddonRepo $AddonConfig
    $text = [IO.File]::ReadAllText($path)
    $text = [regex]::Replace($text,
        '(?m)^<<<<<<< [^\r\n]*\r?\n(version:[^\r\n]*\r?\n)=======\r?\nversion:[^\r\n]*\r?\n>>>>>>> [^\r\n]*\r?\n',
        '$1')
    if ($text -match '(?m)^(<<<<<<<|=======|>>>>>>>)') {
        Stop-Script ("$AddonConfig has merge conflicts besides the version line. Fix them in " +
            "$AddonRepo, run 'git add' and 'git commit --no-edit', then run this script again.")
    }
    $text = [regex]::Replace($text, '(?m)^version:[^\r\n]*', "version: `"$Version`"")
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-GitHubRepo([string]$Repo) {
    $url = [string](Invoke-Git $Repo @('remote', 'get-url', 'origin'))
    $m = [regex]::Match($url, 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?$')
    if (-not $m.Success) { Stop-Script "origin is not a GitHub repository: $url" }
    return @{ Owner = $m.Groups[1].Value; Name = $m.Groups[2].Value }
}

# Polls GitHub until the custom image build for the tag succeeds.
function Wait-ForBuild([string]$ImageTag) {
    $gh = Get-GitHubRepo $GatewayRepo
    $url = "https://api.github.com/repos/$($gh.Owner)/$($gh.Name)/actions/workflows/$BuildWorkflow/runs?branch=$ImageTag&per_page=1"
    $headers = @{}
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $deadline = (Get-Date).AddMinutes($BuildTimeoutMinutes)
    $lastStatus = ''

    while ($true) {
        $run = $null
        try {
            $response = Invoke-RestMethod -Uri $url -Headers $headers -UserAgent 'saic-update-fork'
            if ($response.total_count -gt 0) { $run = @($response.workflow_runs)[0] }
        } catch {
            Write-Warn "GitHub API request failed: $($_.Exception.Message)"
        }

        if ($run) {
            if ($run.status -ne $lastStatus) {
                Write-Info "Build $($run.status): $($run.html_url)"
                $lastStatus = $run.status
            }
            if ($run.status -eq 'completed') {
                if ($run.conclusion -eq 'success') { return }
                Stop-Script ("The image build ended with '$($run.conclusion)': $($run.html_url)`n" +
                    "         Re-run it on GitHub, then run this script again.")
            }
        } elseif (-not $lastStatus) {
            Write-Info 'Waiting for GitHub to start the build...'
            $lastStatus = 'waiting'
        }

        if ((Get-Date) -gt $deadline) {
            Stop-Script "The image build did not finish within $BuildTimeoutMinutes minutes. Run this script again to keep waiting."
        }
        Start-Sleep -Seconds 45
    }
}

function Invoke-Check([string]$Description, [scriptblock]$Command) {
    Write-Info $Description
    & $Command | Out-Host
    if ($LASTEXITCODE -ne 0) { Stop-Script "$Description failed. Nothing was pushed." }
}

# --- 1. Check the repositories ----------------------------------------------------------

Write-Step 'Checking repositories'
Assert-Ready $GatewayRepo -AllowedChanges @('.env')
Assert-Ready $AddonRepo
Invoke-Git $GatewayRepo @('fetch', '--quiet', 'upstream', '--tags') | Out-Null
Invoke-Git $GatewayRepo @('fetch', '--quiet', 'origin', '--tags') | Out-Null
Invoke-Git $AddonRepo @('fetch', '--quiet', 'upstream') | Out-Null
Invoke-Git $AddonRepo @('fetch', '--quiet', 'origin') | Out-Null

foreach ($repo in @($GatewayRepo, $AddonRepo)) {
    if ((Get-AheadCount $repo $Branch "origin/$Branch") -gt 0) {
        Stop-Script "origin/$Branch has commits that $repo does not. Run 'git pull' there first."
    }
}
Write-Info 'Both repositories are on custom and have no uncommitted changes.'

# --- 2. Pick the release ----------------------------------------------------------------

$upstreamReleases = @(Get-RemoteTagNames $GatewayRepo 'upstream' | Where-Object { $_ -match $ReleasePattern } |
    Sort-Object { Get-ReleaseSortKey $_ })
if ($upstreamReleases.Count -eq 0) { Stop-Script 'No release tags found upstream.' }

$mergedReleases = @(Invoke-Git $GatewayRepo @('tag', '--merged', $Branch) |
    Where-Object { $upstreamReleases -contains $_ } | Sort-Object { Get-ReleaseSortKey $_ })
$newestMerged = if ($mergedReleases.Count -gt 0) { $mergedReleases[-1] } else { $null }

if ($Tag) {
    if ($upstreamReleases -notcontains $Tag) { Stop-Script "Upstream has no release tag '$Tag'." }
    if ($newestMerged -and (Get-ReleaseSortKey $Tag) -lt (Get-ReleaseSortKey $newestMerged)) {
        Stop-Script "$Branch already contains $newestMerged, which is newer than $Tag."
    }
} else {
    $Tag = $upstreamReleases[-1]
}

$needsMerge = -not ($mergedReleases -contains $Tag)
$baseVersion = $Tag -replace '-rc\d+$', ''

# Reuse the newest -oc tag whose image matches the current commit (changes under scripts/
# do not end up in the image), otherwise pick the next number.
$ocTags = @(Get-RemoteTagNames $GatewayRepo 'origin' | Where-Object { $_ -match "^$([regex]::Escape($baseVersion))-oc\d+$" } |
    Sort-Object { [int]($_ -replace '^.*-oc', '') })
$headCommit = Get-CommitId $GatewayRepo 'HEAD'
$existingImageTag = $null
if (-not $needsMerge -and $ocTags.Count -gt 0) {
    $newestOc = $ocTags[-1]
    if (Test-Git $GatewayRepo @('diff', '--quiet', "refs/tags/$newestOc", 'HEAD', '--', '.', ':(exclude)scripts')) {
        $existingImageTag = $newestOc
    }
}
$nextNumber = 1 + (@($ocTags | ForEach-Object { [int]($_ -replace '^.*-oc', '') }) + 0 | Measure-Object -Maximum).Maximum
$ImageTag = if ($existingImageTag) { $existingImageTag } else { "$baseVersion-oc$nextNumber" }

$previousAddonVersion = Get-AddonVersion
$addonNeedsMerge = -not (Test-Git $AddonRepo @('merge-base', '--is-ancestor', 'upstream/main', $Branch))
$gatewayUnpushed = Get-AheadCount $GatewayRepo "origin/$Branch" $Branch
$addonUnpushed = Get-AheadCount $AddonRepo "origin/$Branch" $Branch

if (-not $needsMerge -and $existingImageTag -and $gatewayUnpushed -eq 0 -and
    $previousAddonVersion -eq $ImageTag -and -not $addonNeedsMerge -and $addonUnpushed -eq 0) {
    Write-Step 'Already up to date'
    Write-Info "$Branch contains $Tag, image $ImageTag is built and the add-on offers it."
    exit 0
}

# --- 3. Show the plan -------------------------------------------------------------------

Write-Step 'Plan'
$kind = if ($Tag -match '-rc\d+$') { 'release candidate' } else { 'stable release' }
if ($needsMerge) {
    $conflicts = @(Get-MergeConflicts $GatewayRepo $Branch $Tag)
    $mergeNote = if ($conflicts.Count -gt 0) { "conflicts in: $($conflicts -join ', ')" } else { 'merges cleanly' }
    Write-Info "Gateway:   merge $Tag ($kind) into $Branch - $mergeNote"
} else {
    Write-Info "Gateway:   $Branch already contains $Tag ($kind)"
}
$tagNote = if ($existingImageTag) { 'already pushed' } else { 'new' }
Write-Info "Image tag: $ImageTag ($tagNote)"
if ($addonNeedsMerge) {
    $addonConflicts = @(Get-MergeConflicts $AddonRepo $Branch 'upstream/main')
    $addonNote = if ($addonConflicts.Count -gt 0) { "conflicts in: $($addonConflicts -join ', ')" } else { 'merges cleanly' }
    Write-Info "Add-on:    merge upstream/main - $addonNote"
}
Write-Info "Add-on:    version $previousAddonVersion -> $ImageTag"

if ($DryRun) {
    Write-Step 'Dry run: nothing was changed.'
    exit 0
}

# --- 4. Merge the release into the gateway ----------------------------------------------

if ($needsMerge) {
    Write-Step "Merging $Tag into $Branch"
    Invoke-Git $GatewayRepo @('merge', '--no-edit', $Tag) -AllowFailure | Out-Host
    if ($LASTEXITCODE -ne 0) {
        $files = @(Invoke-Git $GatewayRepo @('diff', '--name-only', '--diff-filter=U'))
        Stop-Script ("The merge has conflicts in: $($files -join ', ')`n" +
            "         Fix them in $GatewayRepo, run 'git add <files>' and 'git commit --no-edit',`n" +
            "         then run this script again.")
    }
}

# --- 5. Run the checks ------------------------------------------------------------------

Write-Step 'Running checks'
Push-Location $GatewayRepo
try {
    Invoke-Check 'poetry install' { poetry install --no-root --quiet }
    Invoke-Check 'ruff check' { poetry run ruff check . }
    Invoke-Check 'ruff format' { poetry run ruff format --check . }
    Invoke-Check 'mypy' { poetry run mypy }
    Invoke-Check 'pytest' { poetry run pytest tests -q }
} finally {
    Pop-Location
}

# --- 6. Confirm -------------------------------------------------------------------------

if (-not $Yes) {
    Write-Host ''
    $answer = Read-Host "Push $Branch, push tag $ImageTag, build the image and update the add-on? [y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host 'Cancelled. Nothing was pushed. Run the script again to continue.'
        exit 0
    }
}

# --- 7. Push the gateway and the image tag ----------------------------------------------

Write-Step 'Pushing the gateway'
if ((Get-AheadCount $GatewayRepo "origin/$Branch" $Branch) -gt 0) {
    Invoke-Git $GatewayRepo @('push', 'origin', $Branch) | Out-Host
} else {
    Write-Info "origin/$Branch is already up to date."
}

if (-not $existingImageTag) {
    $localTag = Get-CommitId $GatewayRepo "refs/tags/$ImageTag"
    if ($localTag -and $localTag -ne $headCommit) {
        # An unpushed leftover from an earlier run that points at an older commit.
        Write-Warn "Moving the unpushed local tag $ImageTag to the current commit."
        Invoke-Git $GatewayRepo @('tag', '-f', $ImageTag, $Branch) | Out-Null
    } elseif (-not $localTag) {
        Invoke-Git $GatewayRepo @('tag', $ImageTag, $Branch) | Out-Null
    }
    # Push only this tag. Pushing upstream's plain release tags would build an unpatched image.
    Invoke-Git $GatewayRepo @('push', 'origin', "refs/tags/$ImageTag") | Out-Host
} else {
    Write-Info "Tag $ImageTag is already on GitHub."
}

# --- 8. Wait for the image --------------------------------------------------------------

Write-Step "Waiting for the $ImageTag image build"
Wait-ForBuild $ImageTag
Write-Info 'The image is built.'

# --- 9. Update the add-on ---------------------------------------------------------------

Write-Step "Updating the add-on to $ImageTag"
if ($addonNeedsMerge) {
    Invoke-Git $AddonRepo @('merge', '--no-commit', '--no-ff', 'upstream/main') -AllowFailure | Out-Host
    $conflicted = @(Invoke-Git $AddonRepo @('diff', '--name-only', '--diff-filter=U') | Where-Object { $_ })
    $others = @($conflicted | Where-Object { $_ -ne $AddonConfig })
    if ($others.Count -gt 0) {
        Stop-Script ("The add-on merge has conflicts in: $($others -join ', ')`n" +
            "         Fix them in $AddonRepo, set version to `"$ImageTag`" in $AddonConfig,`n" +
            "         run 'git add <files>' and 'git commit --no-edit', then run this script again.")
    }
}
Set-AddonVersion $ImageTag
Invoke-Git $AddonRepo @('add', $AddonConfig) | Out-Null

$hasStagedChanges = -not (Test-Git $AddonRepo @('diff', '--cached', '--quiet'))
if ((Test-MergeInProgress $AddonRepo) -or $hasStagedChanges) {
    Invoke-Git $AddonRepo @('commit', '--quiet', '-m', "Update custom add-on to $ImageTag",
        '-m', "Custom image is based on upstream $Tag gateway.") | Out-Host
}
if ((Get-AheadCount $AddonRepo "origin/$Branch" $Branch) -gt 0) {
    Invoke-Git $AddonRepo @('push', 'origin', $Branch) | Out-Host
} else {
    Write-Info "origin/$Branch is already up to date."
}

# --- 10. Summary ------------------------------------------------------------------------

$addonText = [IO.File]::ReadAllText((Join-Path $AddonRepo $AddonConfig))
$newOptions = @()
if (Get-CommitId $GatewayRepo "refs/tags/$previousAddonVersion") {
    $before = Get-GatewayEnvVars "refs/tags/$previousAddonVersion"
    $newOptions = @(Get-GatewayEnvVars $Branch | Where-Object {
            ($before -notcontains $_) -and ($addonText -notmatch "\b$_\b")
        })
}

Write-Step 'Done'
Write-Info "Home Assistant will offer version $ImageTag of the custom add-on."
Write-Info 'To see it now: Settings > Add-ons > Add-on Store > menu (top right) > Check for updates.'
if ($newOptions.Count -gt 0) {
    Write-Warn ("New gateway options the add-on does not expose (they use their defaults): " +
        ($newOptions -join ', ') + ". Add them to options and schema in $AddonConfig if you need them.")
}
