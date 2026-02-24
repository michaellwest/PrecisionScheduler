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

### Added

- **Exception handling in `ManageJobs()`** — a top-level `try/catch` prevents an unhandled exception
  from breaking the entire refresh cycle. Per-item `try/catch` blocks ensure that a bad schedule item
  or transient Hangfire failure does not abort processing of the remaining items. All caught exceptions
  are logged at `ERROR` level via the Sitecore `Log` API.

## [1.0.0] - 2024-01-01

### Added

- Initial release — Hangfire-based drop-in replacement for the Sitecore built-in task scheduler.
- Supports both native Sitecore recurrence format and raw cron expressions in the Schedule field.
- CM-only deployment via `role:require="Standalone or ContentManagement"`.
- Configurable startup delay, refresh schedule, and misfire behaviour.
