# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Config assembly name typo** — `PrecisionsScheduler` corrected to `PrecisionScheduler` in
  `PrecisionScheduler.config` and in the README configuration example. On a vanilla install with
  `PackageReference` the processor would silently fail to load. If you referenced the old (misspelled)
  assembly name anywhere in your own config patches, update those references accordingly.
- **Silent schedule skipping** — schedule items with an empty or unrecognised recurrence expression
  are now logged at `WARN` level (including the Sitecore item path) instead of being silently skipped.
- **Missed-run detection accuracy** — the previous `NextExecution - LastRun > 24 h` heuristic was
  incorrect for infrequent jobs (a weekly job always exceeded the threshold, so it would always trigger
  a catch-up on restart) and for sub-daily jobs (a stale catch-up from hours ago adds no value). Now
  uses Cronos to compute the actual next cron occurrence after `LastRun` for precise detection.

### Added

- **Exception handling in `ManageJobs()`** — a top-level `try/catch` prevents an unhandled exception
  from breaking the entire refresh cycle. Per-item `try/catch` blocks ensure that a bad schedule item
  or transient Hangfire failure does not abort processing of the remaining items. All caught exceptions
  are logged at `ERROR` level via the Sitecore `Log` API.
- **Hybrid frequency-aware startup catch-up** — replaces the hardcoded 24-hour lookback window.
  Sub-daily jobs (hourly, every N minutes) only fire a catch-up if the missed run falls within one
  interval of now; infrequent jobs (daily or longer) use a configurable absolute window so a weekly
  job down for several weeks still catches up.
- **`StartupCatchUpEnabled`** config property (default `true`) — master switch to disable all startup
  catch-up and let jobs resume normal cadence without any catch-up execution.
- **`MissedJobLookbackDays`** config property (default `30`) — controls how far back (in days)
  PrecisionScheduler looks for missed runs of infrequent jobs on startup.
- **Explicit `Cronos` 0.8.4 dependency** — used for cron-aware missed-run detection. Cronos is
  already embedded in `Hangfire.Core` as an internal type; the explicit reference exposes the public
  API. No additional DLL is added to the output.

### Changed

- **`MisfireBehavior` renamed to `RefreshMisfireBehavior`** (**breaking**) — clarifies that this
  property controls Hangfire's handling of missed ticks of the `ManageJobs` sync job only, not
  individual Sitecore schedule items. Update your config patch if you set this property explicitly.
  The `FireAll` option has been removed; re-running a sync job N times after N missed ticks adds no
  value. Valid options are now `FireOnce` (default) and `Ignore`.
- **`RecurringJobOptions` used for all `AddOrUpdate` calls** — both the update and register paths
  now use the options-object overload instead of the bare `TimeZoneInfo` overload, consistent with
  the options used for the `ManageJobs` refresh job.
- **`Scheduler` class refactored for readability** — `ManageJobs` decomposed into focused private
  methods (`BuildScheduleDictionary`, `SyncHangfireJobs`, `RunMissedJobsOnStartup`,
  `ShouldFireCatchUp`, `StartJob`, `ParseRefreshMisfireBehavior`). No behaviour change.

## [1.0.0] - 2024-01-01

### Added

- Initial release — Hangfire-based drop-in replacement for the Sitecore built-in task scheduler.
- Supports both native Sitecore recurrence format and raw cron expressions in the Schedule field.
- CM-only deployment via `role:require="Standalone or ContentManagement"`.
- Configurable startup delay, refresh schedule, and misfire behaviour.
