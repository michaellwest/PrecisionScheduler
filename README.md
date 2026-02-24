# PrecisionScheduler for Sitecore

PrecisionScheduler for Sitecore is a drop-in replacement for the standard Task Scheduling found in Sitecore. Check out [this article](https://michaellwest.blogspot.com/2022/08/replacement-task-scheduler-for-sitecore.html) for more details.

## Required Dependencies

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
| `MisfireBehavior` | `FireAll` | How Hangfire handles missed job executions. Options: `Ignore`, `FireOnce`, `FireAll` |

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
          <!-- Options: Ignore | FireOnce | FireAll (Default) -->
          <MisfireBehavior>FireAll</MisfireBehavior>
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
PrecisionScheduler checks for missed runs at startup using a 24-hour lookback window. If a job's last recorded run is more than 24 hours before its next expected execution, it is queued immediately. Set `MisfireBehavior` to `Ignore` to suppress this behaviour.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a full history of changes.