# PrecisionScheduler for Sitecore

PrecisionScheduler for Sitecore is a drop-in replacement for the standard Task Scheduling found in Sitecore. Check out [this article](https://michaellwest.blogspot.com/2022/08/replacement-task-scheduler-for-sitecore.html) for more details.

## Required Dependencies

* Cronos
* Hangfire.AspNet
* Hangfire.Core
* Hangfire.MemoryStorage
* Sitecore.Kernel
* Sitecore.Owin

## Configuration

Your existing schedules should "just work". If you would like to make use of more advanced scheduling, you can use a cron expression directly in the _Schedule_ field of a Sitecore scheduled task item.

### Configuration Reference

| Property | Default | Description |
|---|---|---|
| `StartupDelaySeconds` | `30` | Seconds to wait after OWIN startup before the first schedule sync |
| `RefreshSchedule` | `*/2 * * * *` | Cron expression controlling how often schedules are synced from Sitecore |
| `RefreshMisfireBehavior` | `FireOnce` | How Hangfire handles missed ticks of the sync job itself. Options: `FireOnce`, `Ignore`. Does **not** affect individual Sitecore schedule items — see below |
| `StartupCatchUpEnabled` | `true` | Whether to fire a single catch-up execution for jobs that missed their window during an outage or restart. Set to `false` to resume normal cadence without any catch-up |
| `MissedJobLookbackDays` | `30` | How far back (in days) to look for missed runs on startup. Applies to infrequent jobs (daily or longer) only. Sub-daily jobs (hourly, every N minutes) always use a one-interval window since their next run is imminent |

> **Note:** PrecisionScheduler is CM-only. The processor is gated by `role:require="Standalone or ContentManagement"` and will not activate on CD or other roles.

### NuGet PackageReference

If you are installing using `PackageReference` instead of `packages.config` you'll want to either copy over the configuration files included in this repo or create your own.

```xml
<?xml version="1.0" encoding="utf-8" ?>
<configuration xmlns:patch="http://www.sitecore.net/xmlconfig/" xmlns:set="http://www.sitecore.net/xmlconfig/set/" xmlns:role="http://www.sitecore.net/xmlconfig/role/">
  <sitecore role:require="Standalone or ContentManagement">
    <pipelines>
      <owin.initialize>
        <processor type="PrecisionScheduler.Pipelines.Initialize.Scheduler, PrecisionScheduler">
          <StartupDelaySeconds>30</StartupDelaySeconds>
          <RefreshSchedule>*/2 * * * *</RefreshSchedule>
          <!-- Options: FireOnce (Default), Ignore -->
          <RefreshMisfireBehavior>FireOnce</RefreshMisfireBehavior>
          <!-- Set to false to disable startup catch-up entirely -->
          <StartupCatchUpEnabled>true</StartupCatchUpEnabled>
          <!-- Lookback window for infrequent (daily+) jobs; sub-daily jobs use one-interval window -->
          <MissedJobLookbackDays>30</MissedJobLookbackDays>
        </processor>
      </owin.initialize>
    </pipelines>
    <scheduling>
      <!-- Replaced by the PrecisionScheduler -->
      <agent name="Master_Database_Agent">
        <patch:attribute name="interval" value="00:00:00" />
      </agent>
    </scheduling>
  </sitecore>
</configuration>
```

### Cron vs Sitecore Recurrence Format

PrecisionScheduler accepts both formats in the _Schedule_ field:

| Format | Example | Meaning |
|---|---|---|
| Sitecore recurrence | `20010101T000000\|20990101T000000\|127\|01:00:00` | Every hour, all days |
| Cron expression | `0 * * * *` | Every hour, on the hour |

When a cron expression is detected (matches the standard 5-part cron pattern) it is used as-is. Otherwise the native Sitecore recurrence string is parsed and converted to a cron expression automatically.

## Troubleshooting

**Processor not loading after install**
Verify the assembly name in your config patch matches `PrecisionScheduler` (no trailing _s_). The correct type reference is:
```
type="PrecisionScheduler.Pipelines.Initialize.Scheduler, PrecisionScheduler"
```

**Jobs not firing**
Check the Sitecore log for `[PrecisionScheduler]` entries. A `WARN` entry for a schedule item means its recurrence field is empty or could not be parsed. A `ERROR` entry means an exception occurred during a refresh cycle — the scheduler will retry on the next tick.

**Unexpected jobs firing on startup**
PrecisionScheduler uses a frequency-aware catch-up window to decide whether to queue a missed job on restart:

- **Sub-daily jobs** (hourly, every N minutes) — only fire a catch-up if the missed run is within one interval of now. If the next slot has already passed too, the job resumes its normal cadence.
- **Infrequent jobs** (daily or longer) — fire a catch-up if the miss falls within `MissedJobLookbackDays` (default 30). This ensures a weekly job down over a weekend still catches up rather than waiting another full week.

To disable all startup catch-up, set `StartupCatchUpEnabled` to `false`. To narrow the window for infrequent jobs, lower `MissedJobLookbackDays`.

**Jobs not catching up after a long outage**
If a missed run is older than `MissedJobLookbackDays`, it is skipped and the job resumes its next scheduled occurrence. Increase `MissedJobLookbackDays` to extend the window, or set `StartupCatchUpEnabled` to `false` and handle catch-up manually.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a full history of changes.