<#
.SYNOPSIS
    Creates GitHub issues for PrecisionScheduler improvement tasks.

.DESCRIPTION
    Uses the GitHub REST API to create labelled issues representing the
    improvement recommendations identified during code analysis.
    Run once to seed the issue tracker; subsequent runs skip existing issues
    by title to avoid duplicates.

.PARAMETER Token
    GitHub Personal Access Token with repo scope.
    If omitted, the script reads the GITHUB_TOKEN environment variable.

.PARAMETER Repo
    GitHub repository in "owner/name" format.
    Defaults to "michaellwest/PrecisionScheduler".

.PARAMETER DryRun
    Print what would be created without calling the API.

.EXAMPLE
    .\github-issues.ps1 -Token "ghp_..."

.EXAMPLE
    $env:GITHUB_TOKEN = "ghp_..."
    .\github-issues.ps1

.EXAMPLE
    .\github-issues.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$Repo  = "michaellwest/PrecisionScheduler",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-AuthHeaders {
    if (-not $Token) {
        throw "No GitHub token found. Pass -Token or set `$env:GITHUB_TOKEN."
    }
    return @{
        Authorization          = "Bearer $Token"
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
}

function Get-ExistingLabels {
    $uri = "https://api.github.com/repos/$Repo/labels?per_page=100"
    $response = Invoke-RestMethod -Uri $uri -Headers (Get-AuthHeaders) -Method Get
    return $response | ForEach-Object { $_.name }
}

function New-Label {
    param([string]$Name, [string]$Color, [string]$Description)
    $uri  = "https://api.github.com/repos/$Repo/labels"
    $body = @{ name = $Name; color = $Color; description = $Description } | ConvertTo-Json
    Invoke-RestMethod -Uri $uri -Headers (Get-AuthHeaders) -Method Post `
        -Body $body -ContentType "application/json" | Out-Null
    Write-Host "  Created label: $Name" -ForegroundColor Green
}

function Ensure-Labels {
    param([string[]]$Required)
    $existing = Get-ExistingLabels

    $definitions = @{
        "priority: high"    = @{ color = "d73a4a"; description = "Must be addressed urgently" }
        "priority: medium"  = @{ color = "e4a317"; description = "Important but not blocking" }
        "priority: low"     = @{ color = "0075ca"; description = "Nice to have" }
        "type: bug"         = @{ color = "d73a4a"; description = "Something is incorrect" }
        "type: enhancement" = @{ color = "a2eeef"; description = "New feature or improvement" }
        "type: testing"     = @{ color = "7057ff"; description = "Related to test coverage" }
        "type: docs"        = @{ color = "0052cc"; description = "Documentation improvements" }
        "type: refactor"    = @{ color = "e4e669"; description = "Code structure changes" }
    }

    foreach ($label in $Required) {
        if ($existing -notcontains $label) {
            if ($definitions.ContainsKey($label)) {
                $def = $definitions[$label]
                if ($DryRun) {
                    Write-Host "  [DryRun] Would create label: $label" -ForegroundColor Cyan
                } else {
                    New-Label -Name $label -Color $def.color -Description $def.description
                }
            } else {
                Write-Warning "Label '$label' has no definition - skipping creation."
            }
        }
    }
}

function Get-ExistingIssueTitles {
    $titles = @()
    $page   = 1
    do {
        $uri      = ("https://api.github.com/repos/{0}/issues?state=all" +
                     "&per_page=100&page={1}") -f $Repo, $page
        $response = Invoke-RestMethod -Uri $uri -Headers (Get-AuthHeaders) -Method Get
        $titles  += $response | ForEach-Object { $_.title }
        $page++
    } while ($response.Count -eq 100)
    return $titles
}

function New-Issue {
    param([string]$Title, [string]$Body, [string[]]$Labels)
    $uri    = "https://api.github.com/repos/$Repo/issues"
    $payload = @{ title = $Title; body = $Body; labels = $Labels } | ConvertTo-Json -Depth 5
    $result  = Invoke-RestMethod -Uri $uri -Headers (Get-AuthHeaders) -Method Post `
        -Body $payload -ContentType "application/json"
    return $result.html_url
}

# ---------------------------------------------------------------------------
# Issue definitions  (bodies use single-quoted here-strings - no expansion)
# ---------------------------------------------------------------------------

$issues = @(

    # -----------------------------------------------------------------------
    # HIGH PRIORITY
    # -----------------------------------------------------------------------
    @{
        Title  = "Add exception handling around ManageJobs method"
        Labels = @("priority: high", "type: bug")
        Body   = @'
## Problem

The `ManageJobs()` method (and the methods it calls) contains no try-catch blocks.
A single transient database error, a bad schedule item, or a Hangfire API failure will
crash the entire refresh cycle and leave the scheduler silently broken until the next
OWIN restart.

## Affected code

- `Scheduler.cs` - `ManageJobs()`
- All inner calls: database queries, Hangfire `AddOrUpdate` / `RemoveIfExists`

## Acceptance criteria

- [ ] All database operations inside `ManageJobs()` are wrapped in try-catch
- [ ] Exceptions are logged via the existing `LogMessage()` helper at `Error` level
- [ ] A failure processing one schedule item does not abort processing the remaining items
- [ ] The refresh timer continues running after a handled exception
'@
    },

    @{
        Title  = "Fix assembly name typo in PrecisionScheduler.config"
        Labels = @("priority: high", "type: bug")
        Body   = @'
## Problem

The Sitecore config file references the wrong assembly name:

```xml
type="PrecisionScheduler.Pipelines.Initialize.Scheduler, PrecisionsScheduler"
```

`PrecisionsScheduler` (with a spurious **s**) does not match the actual assembly
`PrecisionScheduler`. Sitecore will fail to resolve the type and the processor will
never run on a clean install.

## Affected file

`src/App_Config/Modules/PrecisionScheduler/PrecisionScheduler.config` - line 6

## Acceptance criteria

- [ ] Assembly name corrected to `PrecisionScheduler` (no trailing *s*)
- [ ] Config loads and processor activates correctly on a vanilla Sitecore 10.4 instance
'@
    },

    @{
        Title  = "Log a warning when a schedule item is invalid or skipped"
        Labels = @("priority: high", "type: enhancement")
        Body   = @'
## Problem

When a schedule item has an empty or unrecognisable recurrence string the code silently
calls `continue`, giving operators no indication that the item was skipped.
This makes it very hard to diagnose misconfigured schedule items in production.

## Acceptance criteria

- [ ] A `Warning`-level log entry is written whenever a schedule is skipped due to an empty recurrence value
- [ ] A `Warning`-level log entry is written whenever cron/recurrence parsing fails
- [ ] The log entry includes the Sitecore item path so operators can locate the offending item
'@
    },

    # -----------------------------------------------------------------------
    # MEDIUM PRIORITY
    # -----------------------------------------------------------------------
    @{
        Title  = "Add unit test project for cron generation and schedule parsing"
        Labels = @("priority: medium", "type: testing")
        Body   = @'
## Problem

The repository has zero test coverage. The schedule-parsing and cron-generation logic
is complex, handles many edge cases, and is entirely untestable in its current form
because it is tightly coupled to Sitecore APIs.

## Scope

The following methods are pure logic with no Sitecore dependency and can be unit-tested
today without any mocking:

- `ParseCronTimeSpan(string)` - TimeSpan-formatted string to cron expression
- `GenerateMultiDayCronExpression(int, TimeSpan)` - bitmask days + interval to cron
- `ParseDays(int)` - Sitecore day bitmask to `DayOfWeek[]`
- Cron regex validation logic

## Acceptance criteria

- [ ] A new test project `PrecisionScheduler.Tests` is added to the solution
- [ ] Tests cover happy-path and edge-case inputs for each method listed above
- [ ] Tests run via `dotnet test` with no Sitecore dependencies required
- [ ] CI/CD pipeline (if added) includes the test step
'@
    },

    @{
        Title  = "Split Scheduler class into initializer and schedule manager"
        Labels = @("priority: medium", "type: refactor")
        Body   = @'
## Problem

`Scheduler` currently serves two distinct responsibilities:

1. **OWIN pipeline initialisation** - registering Hangfire, starting the server, scheduling the refresh job
2. **Schedule management** - scanning Sitecore, diffing against Hangfire state, adding/removing recurring jobs

Mixing these concerns makes the class harder to read, test, and extend.

## Proposed structure

- `SchedulerInitializer : InitializeProcessor` - thin OWIN entry point, delegates to manager
- `ScheduleManager` - all job-sync logic, no dependency on OWIN pipeline types

## Acceptance criteria

- [ ] `SchedulerInitializer` contains only OWIN pipeline wiring
- [ ] `ScheduleManager` is independently instantiable and testable
- [ ] No change in observable behaviour
'@
    },

    @{
        Title  = "Replace ServiceLocator with constructor injection"
        Labels = @("priority: medium", "type: refactor")
        Body   = @'
## Problem

The codebase uses `ServiceLocator.ServiceProvider` (a service-locator anti-pattern)
which hides dependencies and makes the classes impossible to unit test without a
running Sitecore instance.

## Acceptance criteria

- [ ] Dependencies (e.g., `IRecurringJobManager`, database access) are injected via constructor parameters
- [ ] `Scheduler` / `ScheduleManager` accept their dependencies through the constructor
- [ ] Sitecore's DI container registers the types in `RegisterCustomDependencies` or equivalent
- [ ] Unit tests can supply fakes/mocks without requiring a live Sitecore environment
'@
    },

    @{
        Title  = "Replace Activator.CreateInstance with direct instantiation for JobRunner"
        Labels = @("priority: medium", "type: refactor")
        Body   = @'
## Problem

`JobRunner` is created via reflection:

```csharp
Activator.CreateInstance(typeof(JobRunner))
```

This is brittle - exceptions thrown during construction are wrapped in
`TargetInvocationException` and are difficult to diagnose. It also bypasses
compile-time type safety.

## Acceptance criteria

- [ ] `JobRunner` is instantiated directly (`new JobRunner()`) or via a registered factory
- [ ] Any constructor exceptions surface with their original type and message
- [ ] No functional change in job execution behaviour
'@
    },

    @{
        Title  = "Change MisfireBehavior default to Ignore and fix config/code mismatch"
        Labels = @("priority: medium", "type: bug")
        Body   = @'
## Problem

There is a mismatch between what the config advertises and what the code does:

- The config comment lists `Relaxed` as a valid option and implies it is the default
- The code currently defaults to `FireAll` when no value is configured

The intended default (confirmed: `Ignore`) is documented in neither place correctly.
`Ignore` is the safest default for a drop-in replacement because it prevents a flood
of missed-job executions when the scheduler first starts or after a deployment.

## Affected files

- `src/Pipelines/Initialize/Scheduler.cs` - default MisfireBehavior value
- `src/App_Config/Modules/PrecisionScheduler/PrecisionScheduler.config` - comment listing valid values and default

## Acceptance criteria

- [ ] Code default changed to `Ignore` when `MisfireBehavior` is not set in config
- [ ] Config comment updated to list all valid values: `Relaxed | Ignore | FireOnce | FireAll`
- [ ] Config comment clearly indicates `Ignore` is the default
- [ ] Behaviour change is noted in `CHANGELOG.md` as a **breaking change** for anyone relying on the previous default
'@
    },

    # -----------------------------------------------------------------------
    # LOW PRIORITY
    # -----------------------------------------------------------------------
    @{
        Title  = "Make the missed-job lookback window configurable"
        Labels = @("priority: low", "type: enhancement")
        Body   = @'
## Problem

The window used to detect missed job executions on startup is hardcoded to 24 hours:

```csharp
var missedLastRun = recurringJob.NextExecution - scheduleItem.LastRun > TimeSpan.FromHours(24);
```

Operators with long-running or infrequent schedules may need a larger window; those
with high-frequency schedules may prefer a shorter one.

## Acceptance criteria

- [ ] A new `MissedJobLookbackHours` property is added to the config processor element (default: `24`)
- [ ] The hardcoded `TimeSpan.FromHours(24)` is replaced with the configured value
- [ ] `PrecisionScheduler.config` documents the new property with an inline comment
'@
    },

    @{
        Title  = "Add XML documentation comments to public API"
        Labels = @("priority: low", "type: docs")
        Body   = @'
## Problem

No public methods or properties carry `///` XML documentation comments.
This means IntelliSense shows no descriptions and tools like DocFX cannot generate
API reference documentation.

## Acceptance criteria

- [ ] All `public` and `internal` methods have `<summary>` XML doc comments
- [ ] Parameters with non-obvious semantics have `<param>` comments
- [ ] The project file enables `<GenerateDocumentationFile>true</GenerateDocumentationFile>`
- [ ] No doc-comment warnings (CS1591) are suppressed
'@
    },

    @{
        Title  = "Implement delta detection to avoid redundant Hangfire updates on refresh"
        Labels = @("priority: low", "type: enhancement")
        Body   = @'
## Problem

On every refresh cycle (default: every 2 minutes) the full schedule dictionary is rebuilt
from scratch and all jobs are unconditionally re-evaluated. On Sitecore instances with
many schedule items this generates unnecessary database reads and Hangfire API calls even
when nothing has changed.

## Proposed approach

Track a hash or last-modified timestamp per schedule item and skip the `AddOrUpdate`
call when the cron expression is unchanged. Only modified, new, or removed items should
be actioned.

## Acceptance criteria

- [ ] Unchanged schedule items produce no Hangfire API call during a refresh cycle
- [ ] New items are added, modified items updated, and removed items deleted as before
- [ ] A debug-level log entry records the number of items added/updated/removed per cycle
'@
    },

    @{
        Title  = "Expand README with troubleshooting, configuration reference, and changelog"
        Labels = @("priority: low", "type: docs")
        Body   = @'
## Problem

The README delegates most explanation to an external blog post. This creates a
dependency on content outside the repository and gives new users no quick reference
for common issues.

## Acceptance criteria

- [ ] A **Configuration reference** table documents all XML properties and their defaults
- [ ] A **Cron vs Sitecore recurrence format** section shows side-by-side examples
- [ ] A **Troubleshooting** section covers common failure modes (processor not loading, jobs not firing, misfire behaviour)
- [ ] A **Changelog** section (or `CHANGELOG.md`) summarises changes per release
- [ ] CM-only constraint (`role:require`) is explicitly documented
'@
    }
)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "PrecisionScheduler -- GitHub Issue Creator" -ForegroundColor Cyan
Write-Host "Repo  : $Repo"
Write-Host "Issues: $($issues.Count)"
if ($DryRun) { Write-Host "Mode  : DRY RUN (no API calls)" -ForegroundColor Yellow }
Write-Host ""

# Collect all labels used across all issues
$allLabels = $issues | ForEach-Object { $_.Labels } | Sort-Object -Unique

if (-not $DryRun) {
    Write-Host "Ensuring labels exist..." -ForegroundColor Cyan
    Ensure-Labels -Required $allLabels

    Write-Host ""
    Write-Host "Fetching existing issue titles..." -ForegroundColor Cyan
    $existingTitles = Get-ExistingIssueTitles
    Write-Host "  Found $($existingTitles.Count) existing issue(s)."
} else {
    $existingTitles = @()
}

Write-Host ""
Write-Host "Creating issues..." -ForegroundColor Cyan

$created = 0
$skipped = 0

foreach ($issue in $issues) {
    if ($existingTitles -contains $issue.Title) {
        Write-Host "  SKIP  (already exists): $($issue.Title)" -ForegroundColor DarkGray
        $skipped++
        continue
    }

    if ($DryRun) {
        Write-Host "  [DryRun] Would create: $($issue.Title)" -ForegroundColor Cyan
        Write-Host "           Labels: $($issue.Labels -join ', ')" -ForegroundColor DarkCyan
        $created++
        continue
    }

    try {
        $url = New-Issue -Title $issue.Title -Body $issue.Body -Labels $issue.Labels
        Write-Host "  CREATED: $($issue.Title)" -ForegroundColor Green
        Write-Host "           $url" -ForegroundColor DarkGreen
        $created++
        # Respect GitHub secondary rate limit
        Start-Sleep -Milliseconds 500
    } catch {
        Write-Warning "  FAILED : $($issue.Title)"
        Write-Warning "  Error  : $_"
    }
}

Write-Host ""
Write-Host "Done. Created: $created  |  Skipped: $skipped" -ForegroundColor Cyan
Write-Host ""
