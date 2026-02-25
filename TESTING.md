# PrecisionScheduler — Integration Test Plan

Validation checklist for testing PrecisionScheduler on a vanilla Sitecore 10.x CM instance.

---

## 1. Installation

- [ ] Drop `PrecisionScheduler.dll` and `PrecisionScheduler.config` into the Sitecore web root
- [ ] Verify no startup errors in `log.txt` — look for `[PrecisionScheduler] Starting up precision scheduler.`
- [ ] Verify the native scheduler is silenced — `Master_Database_Agent` should appear in config with `interval="00:00:00"` (confirm via `/sitecore/admin/showconfig.aspx`)
- [ ] Confirm OWIN pipeline registered — search `log.txt` for the processor being invoked in `owin.initialize`

---

## 2. Job Registration (Schedule Sync)

After the `StartupDelaySeconds` (30s by default) elapses:

- [ ] `[PrecisionScheduler] Registering recurring job for {itemId}` logged for **every** schedule item under `/sitecore/system/tasks/schedules`
- [ ] Out-of-the-box Sitecore schedules are picked up (e.g. `PublishAgent`, `UrlAgent`, `CleanupAgent`)
- [ ] Any schedule item with a **blank recurrence** field logs a `Skipping schedule item` warning and is excluded — no crash
- [ ] The `ManageJobs` recurring job appears in Hangfire's in-memory store (indirectly visible via the next point)
- [ ] `ManageJobs` re-runs every 2 minutes (watch `log.txt` for steady `Registering`/no-op cycling)

---

## 3. Schedule Format Compatibility

Test one schedule item of each format:

| Format | Example value | Expected cron |
|---|---|---|
| Native Sitecore recurrence | `20010101T000000\|20991231T235959\|127\|01:00:00` | `0 */1 * * 0,1,2,3,4,5,6` |
| Every N minutes | `20010101T000000\|20991231T235959\|127\|00:05:00` | `*/5 * * * *` |
| Specific days only | `...127...` → all days; `...62...` → Mon–Fri | Correct DOW field |
| Raw cron string in Schedule field | `*/10 * * * *` | Passed through unchanged |

- [ ] Each format logs the correct cron string on registration

---

## 4. Job Execution

Pick a simple Sitecore task (e.g. `PublishAgent` or a custom test task that writes to `log.txt`):

- [ ] Wait for its cron schedule to fire
- [ ] `[PrecisionScheduler] Running background job for {itemId}` appears in log
- [ ] The underlying `ScheduleItem.Execute()` runs without error
- [ ] Running the same job while it's already executing logs `already running` and skips the duplicate

---

## 5. Startup Catch-Up

Simulate a server outage:

- [ ] Set `LastRun` on a **daily** schedule item to yesterday (edit field directly in Sitecore content editor)
- [ ] Restart IIS / recycle app pool
- [ ] Within 30s of startup, verify `[PrecisionScheduler] Running missed job {itemId}` fires for that item
- [ ] A **sub-daily** (e.g. every 5 min) schedule item with a stale `LastRun` does **not** fire catch-up if the next slot has already passed — verify only the skip log appears
- [ ] Set `StartupCatchUpEnabled` to `false` in config → restart → confirm **no** catch-up fires for any job

---

## 6. Dynamic Schedule Changes

While the instance is running:

- [ ] **Add** a new schedule item in Sitecore Content Editor → within 2 minutes, verify it gets registered in the next `ManageJobs` cycle
- [ ] **Delete** a schedule item → within 2 minutes, verify `[PrecisionScheduler] Removing {itemId} from recurring schedule.`
- [ ] **Change** the recurrence field on an existing item → within 2 minutes, verify `Updating {itemId} with a new schedule` is logged

---

## 7. Error Resilience

- [ ] Create a schedule item whose **command** class doesn't exist — verify `[PrecisionScheduler] Error ...` is logged, but subsequent `ManageJobs` ticks continue running (no runaway crash loop)
- [ ] Temporarily corrupt a schedule item's recurrence field to garbage text → verify `Skipping ... empty or unrecognised recurrence` warning, no crash, item is excluded

---

## 8. Config Knobs

| Setting | Test |
|---|---|
| `StartupDelaySeconds` | Set to `5` — confirm jobs register faster after restart |
| `RefreshSchedule` | Set to `*/5 * * * *` — confirm ManageJobs cycles every 5 min |
| `MissedJobLookbackDays` | Set to `1` — confirm jobs older than 1 day do NOT catch up |
| `RefreshMisfireBehavior=Ignore` | Stop app for a few minutes, restart — ManageJobs fires once, not twice |

---

## 9. Logging Hygiene

- [ ] No `[PrecisionScheduler]` errors or warnings appear during a clean run with default Sitecore schedules
- [ ] Logs are prefixed consistently — grep `[PrecisionScheduler]` in `log.txt` and verify all messages are attributable to expected operations
- [ ] No `Sitecore.Diagnostics.Log` calls from other sources are polluted or suppressed

---

## 10. Native Scheduler Coexistence

- [ ] Verify the native `Sitecore.Tasks.Master_Database_Agent` is **not firing** (interval is zeroed out by the patch)
- [ ] Install on a **CD role** — config should be absent (`role:require="Standalone or ContentManagement"`) — no Hangfire server starts, no schedule polling

---

## Pass Criteria

A passing integration test is:

1. **Clean startup log** — registered message for every existing schedule item, no errors
2. **Jobs execute on time** — within one cron interval of their scheduled window
3. **Catch-up fires correctly** — stale daily jobs run; stale sub-daily jobs skip
4. **Dynamic sync works** — add/remove/edit schedules reflected within 2 minutes
5. **Errors are isolated** — one bad schedule item doesn't break all others
6. **Native scheduler is silent** — no duplicate execution from the built-in agent
