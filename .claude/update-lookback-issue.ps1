<#
.SYNOPSIS
    Finds and updates the "Make the missed-job lookback window configurable" GitHub issue
    to reflect the hybrid frequency-aware implementation that was shipped.

.PARAMETER Token
    GitHub Personal Access Token with repo scope.
    If omitted, reads $env:GITHUB_TOKEN.

.EXAMPLE
    .\.claude\update-lookback-issue.ps1 -Token "ghp_..."
#>
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$Repo  = "michaellwest/PrecisionScheduler"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Token) { throw "No GitHub token. Pass -Token or set `$env:GITHUB_TOKEN." }

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# Find the issue by title
$page = 1
$target = $null
do {
    $uri      = "https://api.github.com/repos/$Repo/issues?state=open&per_page=100&page=$page"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    $target   = $response | Where-Object { $_.title -like "*missed-job lookback*" -or $_.title -like "*lookback window*" }
    $page++
} while (-not $target -and $response.Count -eq 100)

if (-not $target) {
    Write-Warning "Could not find the lookback issue. Listing all open issues for manual search:"
    $allIssues = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/issues?state=open&per_page=50" -Headers $headers
    $allIssues | Select-Object number, title | Format-Table -AutoSize
    return
}

$issueNumber = $target.number
Write-Host "Found issue #$issueNumber : $($target.title)" -ForegroundColor Cyan

$newBody = @'
## Implementation

This issue has been implemented as a hybrid frequency-aware lookback window via the
`MissedJobLookbackDays` config property (default: `30`).

## How it works

The window adapts based on each job's own interval rather than applying a single
fixed threshold across all jobs:

**Frequent jobs (sub-daily — e.g. every 5 min, hourly):**
Only fire a catch-up if the miss is within one interval of now. If the next slot
has already passed too, the following run is imminent — a stale catch-up adds no value.

**Infrequent jobs (daily or longer — e.g. daily at 09:00, every Saturday):**
Fire a catch-up if the miss falls within `MissedJobLookbackDays` days. A weekly
job down for 3 weeks should still catch up rather than silently waiting another
full week for the next occurrence.

## Configuration

```xml
<processor type="PrecisionScheduler.Pipelines.Initialize.Scheduler, PrecisionScheduler">
  <!--
    MissedJobLookbackDays: how far back (in days) to look for missed executions on startup.
    Applies only to infrequent jobs whose interval is one day or longer (e.g. daily, weekly).
    Sub-daily jobs always use a one-interval window regardless of this value.
    Default: 30
  -->
  <MissedJobLookbackDays>30</MissedJobLookbackDays>
</processor>
```

## Behaviour table (MissedJobLookbackDays = 30)

| Job | Downtime | Result |
|---|---|---|
| Every 5 min | 2 h | Skips — sub-daily; next slot already past |
| Hourly | 6 h | Skips — sub-daily; next slot already past |
| Daily 09:00 | 36 h | Fires — infrequent; 36 h < 30 days |
| Every Saturday | 1 week | Fires — infrequent; 1 wk < 30 days |
| Every Saturday | 3 weeks | Fires — infrequent; 3 wks < 30 days |
| Every Saturday | 6 weeks | Skips — infrequent; 6 wks > 30 days |
'@

$payload = @{ body = $newBody; state = "closed"; state_reason = "completed" } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/issues/$issueNumber" `
    -Headers $headers -Method Patch -Body $payload -ContentType "application/json" | Out-Null

Write-Host "Issue #$issueNumber updated and closed." -ForegroundColor Green
Write-Host "https://github.com/$Repo/issues/$issueNumber" -ForegroundColor DarkGreen
