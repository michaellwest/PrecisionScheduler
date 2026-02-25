<#
.SYNOPSIS
    Pushes the reliability/issues-1-2-3 branch, creates a PR, and adds progress
    comments to the three related GitHub issues.

.PARAMETER Token
    GitHub Personal Access Token with repo scope.
    If omitted, reads $env:GITHUB_TOKEN.

.PARAMETER Repo
    GitHub repository in "owner/name" format.

.EXAMPLE
    $env:GITHUB_TOKEN = "ghp_..."
    .\.claude\publish-reliability-pr.ps1
#>

[CmdletBinding()]
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$Repo  = "michaellwest/PrecisionScheduler"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Token) {
    throw "No GitHub token found. Pass -Token or set `$env:GITHUB_TOKEN."
}

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

# ---------------------------------------------------------------------------
# 1. Push branch
# ---------------------------------------------------------------------------
Write-Host "Pushing branch..." -ForegroundColor Cyan
git -C (Split-Path $PSScriptRoot) push --set-upstream origin reliability/issues-1-2-3
Write-Host "Branch pushed." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Resolve issue numbers by title
# ---------------------------------------------------------------------------
$targetTitles = @(
    "Fix assembly name typo in PrecisionScheduler.config",
    "Add exception handling around ManageJobs method",
    "Log a warning when a schedule item is invalid or skipped"
)

Write-Host "Resolving issue numbers..." -ForegroundColor Cyan
$page = 1
$allIssues = @()
do {
    $uri      = "https://api.github.com/repos/$Repo/issues?state=open&per_page=100&page=$page"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    $allIssues += $response
    $page++
} while ($response.Count -eq 100)

$issueNumbers = @{}
foreach ($title in $targetTitles) {
    $match = $allIssues | Where-Object { $_.title -eq $title } | Select-Object -First 1
    if ($match) {
        $issueNumbers[$title] = $match.number
        Write-Host "  #$($match.number) — $title" -ForegroundColor Green
    } else {
        Write-Warning "Could not find issue: $title"
    }
}

$issueRefs = ($issueNumbers.Values | Sort-Object | ForEach-Object { "Closes #$_" }) -join "`n"

# ---------------------------------------------------------------------------
# 3. Create the pull request
# ---------------------------------------------------------------------------
Write-Host "`nCreating pull request..." -ForegroundColor Cyan

$prBody = @"
## Summary

- **Fix #$($issueNumbers[$targetTitles[0]])** — corrected assembly name typo ``PrecisionsScheduler`` → ``PrecisionScheduler`` in config file and README example. On a fresh install with ``PackageReference`` the processor would silently fail to load.
- **Fix #$($issueNumbers[$targetTitles[1]])** — added a top-level ``try/catch`` in ``ManageJobs()`` so an unhandled exception no longer breaks the entire refresh cycle, plus per-item ``try/catch`` so a bad schedule item does not abort remaining items.
- **Fix #$($issueNumbers[$targetTitles[2]])** — schedule items with an empty or unrecognised recurrence expression now emit a ``WARN``-level log entry (including the Sitecore item path) instead of silently continuing.

## Additional changes

- Created ``CHANGELOG.md`` (keep-a-changelog format) documenting these fixes.
- Expanded ``README.md`` with a configuration reference table, cron vs recurrence format comparison, troubleshooting section, and a link to the changelog.

## Test plan

- [ ] Verify config loads on a Sitecore 10.x CM instance (processor activates, log shows startup message)
- [ ] Introduce a schedule item with an invalid recurrence string — confirm ``WARN`` log entry appears with the item path
- [ ] Temporarily throw inside ``ManageJobs()`` — confirm ``ERROR`` is logged and the refresh cycle continues on the next tick
- [ ] Confirm no regression on existing schedules running with native recurrence or cron format

$issueRefs

🤖 Generated with [Claude Code](https://claude.com/claude-code)
"@

$prPayload = @{
    title = "fix: config typo, ManageJobs exception handling, and silent-skip logging"
    body  = $prBody
    head  = "reliability/issues-1-2-3"
    base  = "master"
} | ConvertTo-Json -Depth 5

$pr = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/pulls" `
    -Headers $headers -Method Post -Body $prPayload -ContentType "application/json"

Write-Host "PR created: $($pr.html_url)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Comment on each issue with a progress update
# ---------------------------------------------------------------------------
$progressComments = @{
    $targetTitles[0] = @"
## Progress update

This issue is addressed in PR $($pr.html_url).

**Changes made:**
- ``src/App_Config/Modules/PrecisionScheduler/PrecisionScheduler.config`` line 6: ``PrecisionsScheduler`` → ``PrecisionScheduler``
- ``README.md`` configuration example: same typo corrected

**Acceptance criteria status:**
- [x] Assembly name corrected to ``PrecisionScheduler`` (no trailing *s*)
- [ ] Config loads and processor activates correctly on a vanilla Sitecore 10.4 instance *(verify during PR review)*
"@

    $targetTitles[1] = @"
## Progress update

This issue is addressed in PR $($pr.html_url).

**Changes made in ``ManageJobs()``:**
- Outer ``try/catch`` — prevents an unhandled exception from silently breaking the refresh cycle; logs at ``ERROR`` level
- Per-item ``try/catch`` in all three inner loops (inventory scan, existing-job diff, missing-job registration, startup missed-job check)
- Each caught exception is logged with context (item path or job ID) via the new ``LogError()`` helper

**Acceptance criteria status:**
- [x] All database operations inside ``ManageJobs()`` are wrapped in try-catch
- [x] Exceptions are logged via the existing ``LogMessage()`` helper at ``Error`` level
- [x] A failure processing one schedule item does not abort processing the remaining items
- [x] The refresh timer continues running after a handled exception
"@

    $targetTitles[2] = @"
## Progress update

This issue is addressed in PR $($pr.html_url).

**Changes made:**
- When ``GetSchedule()`` returns an empty string in the inventory loop, a ``WARN`` log entry is now written including the Sitecore item path and item ID
- When an existing recurring job's schedule can no longer be resolved, the existing ``LogMessage`` call was upgraded to ``LogWarning``
- Added ``LogWarning()`` and ``LogError()`` helper methods mirroring the existing ``LogMessage()`` pattern

**Acceptance criteria status:**
- [x] A ``Warning``-level log entry is written whenever a schedule is skipped due to an empty recurrence value
- [x] A ``Warning``-level log entry is written whenever cron/recurrence parsing fails
- [x] The log entry includes the Sitecore item path so operators can locate the offending item
"@
}

Write-Host "`nCommenting on issues..." -ForegroundColor Cyan
foreach ($title in $targetTitles) {
    if (-not $issueNumbers.ContainsKey($title)) { continue }
    $num     = $issueNumbers[$title]
    $comment = $progressComments[$title]
    $payload = @{ body = $comment } | ConvertTo-Json -Depth 3
    Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/issues/$num/comments" `
        -Headers $headers -Method Post -Body $payload -ContentType "application/json" | Out-Null
    Write-Host "  Commented on #$num" -ForegroundColor Green
    Start-Sleep -Milliseconds 500
}

Write-Host "`nDone!" -ForegroundColor Cyan
Write-Host "PR: $($pr.html_url)" -ForegroundColor Green
