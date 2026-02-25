using Hangfire;
using Hangfire.MemoryStorage;
using Hangfire.Storage;
using Microsoft.Extensions.DependencyInjection;
using Sitecore;
using Sitecore.Abstractions;
using Sitecore.Data;
using Sitecore.Data.Items;
using Sitecore.DependencyInjection;
using Sitecore.Diagnostics;
using Sitecore.Jobs;
using Sitecore.Owin.Pipelines.Initialize;
using Sitecore.Tasks;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace PrecisionScheduler.Pipelines.Initialize
{
    public class Scheduler : InitializeProcessor
    {
        private const string SCHEDULE_DATABASE = "master";

        public string RefreshSchedule { get; set; } = "*/2 * * * *";
        public int StartupDelaySeconds { get; set; } = 15;
        public string RefreshMisfireBehavior { get; set; } = "FireOnce";
        public bool StartupCatchUpEnabled { get; set; } = true;
        public int MissedJobLookbackDays { get; set; } = 30;

        private static void LogMessage(string message) =>
            Log.Info($"[PrecisionScheduler] {message}", nameof(Scheduler));

        private static void LogWarning(string message) =>
            Log.Warn($"[PrecisionScheduler] {message}", nameof(Scheduler));

        private static void LogError(string message, Exception ex) =>
            Log.Error($"[PrecisionScheduler] {message}", ex, nameof(Scheduler));

        public override void Process(InitializeArgs args)
        {
            args.App.UseHangfireAspNet(() =>
            {
                GlobalConfiguration.Configuration.UseMemoryStorage();
                return new[] { new BackgroundJobServer() };
            });

            LogMessage("Starting up precision scheduler.");

            var recurringJobOptions = new RecurringJobOptions
            {
                TimeZone = TimeZoneInfo.Local,
                MisfireHandling = ParseRefreshMisfireBehavior(RefreshMisfireBehavior)
            };

            BackgroundJob.Schedule(
                () => Initialize(RefreshSchedule, recurringJobOptions, StartupCatchUpEnabled, MissedJobLookbackDays),
                TimeSpan.FromSeconds(StartupDelaySeconds));
        }

        // Parses the refresh-job misfire behavior. FireAll is intentionally excluded —
        // running ManageJobs N times in a row after N missed ticks has no benefit for
        // a pure sync operation. FireOnce (Relaxed) and Ignore are the only useful modes.
        private static MisfireHandlingMode ParseRefreshMisfireBehavior(string behavior)
        {
            if (string.Equals(behavior, "Ignore", StringComparison.InvariantCultureIgnoreCase))
                return MisfireHandlingMode.Ignorable;
            // "FireOnce", empty, or unrecognised values fire at most once (Relaxed).
            return MisfireHandlingMode.Relaxed;
        }

        public static void Initialize(string refreshSchedule, RecurringJobOptions jobOptions, bool startupCatchUpEnabled, int missedJobLookbackDays)
        {
            ManageJobs(true, startupCatchUpEnabled, missedJobLookbackDays);
            RecurringJob.AddOrUpdate(nameof(ManageJobs), () => ManageJobs(false, startupCatchUpEnabled, missedJobLookbackDays), refreshSchedule, jobOptions);
        }

        public static void ManageJobs(bool isStartup, bool startupCatchUpEnabled = true, int missedJobLookbackDays = 30)
        {
            try
            {
                var database = ServiceLocator.ServiceProvider.GetRequiredService<BaseFactory>().GetDatabase(SCHEDULE_DATABASE, true);
                var schedules = BuildScheduleDictionary(database);
                SyncHangfireJobs(database, schedules);

                if (isStartup && startupCatchUpEnabled)
                    RunMissedJobsOnStartup(database, schedules, missedJobLookbackDays);
            }
            catch (Exception ex)
            {
                LogError("Unhandled error in ManageJobs — the refresh cycle will retry on the next scheduled tick.", ex);
            }
        }

        private static Dictionary<string, string> BuildScheduleDictionary(Database database)
        {
            var schedules = new Dictionary<string, string>();
            var descendants = database.SelectItems($"/sitecore/system/tasks/schedules//*[@@templateid='{TemplateIDs.Schedule}']");

            foreach (var item in descendants)
            {
                try
                {
                    if (item.TemplateID != TemplateIDs.Schedule) continue;

                    var itemId = item.ID.ToString();
                    var schedule = GetSchedule(item);
                    if (string.IsNullOrEmpty(schedule))
                    {
                        LogWarning($"Skipping schedule item '{item.Paths.Path}' ({itemId}) — empty or unrecognised recurrence value.");
                        continue;
                    }

                    schedules.Add(itemId, schedule);
                }
                catch (Exception ex)
                {
                    LogError($"Error reading schedule item '{item?.Paths?.Path ?? item?.ID?.ToString()}' during inventory.", ex);
                }
            }

            return schedules;
        }

        private static void SyncHangfireJobs(Database database, Dictionary<string, string> schedules)
        {
            var jobs = JobStorage.Current.GetConnection().GetRecurringJobs();
            var existingJobs = new List<string>();

            foreach (var job in jobs)
            {
                try
                {
                    if (!ID.IsID(job.Id)) continue;
                    var itemId = job.Id;

                    if (!schedules.ContainsKey(itemId))
                    {
                        LogMessage($"Removing {itemId} from recurring schedule.");
                        RecurringJob.RemoveIfExists(itemId);
                        continue;
                    }

                    var schedule = GetSchedule(database.GetItem(itemId));
                    if (string.IsNullOrEmpty(schedule))
                    {
                        LogWarning($"Removing {itemId} from recurring schedule — item has an invalid or empty recurrence expression.");
                        RecurringJob.RemoveIfExists(itemId);
                        continue;
                    }

                    if (!string.Equals(job.Cron, schedule, StringComparison.InvariantCultureIgnoreCase))
                    {
                        LogMessage($"Updating {itemId} with a new schedule '{schedule}'.");
                        RecurringJob.AddOrUpdate($"{itemId}", () => RunSchedule(ID.Parse(itemId)), schedule, new RecurringJobOptions { TimeZone = TimeZoneInfo.Local });
                    }

                    existingJobs.Add(itemId);
                }
                catch (Exception ex)
                {
                    LogError($"Error managing recurring job '{job?.Id}'.", ex);
                }
            }

            foreach (var missingJob in schedules.Keys.Except(existingJobs))
            {
                try
                {
                    var schedule = GetSchedule(database.GetItem(missingJob));
                    LogMessage($"Registering recurring job for {missingJob} with schedule '{schedule}'.");
                    RecurringJob.AddOrUpdate($"{missingJob}", () => RunSchedule(ID.Parse(missingJob)), schedule, new RecurringJobOptions { TimeZone = TimeZoneInfo.Local });
                }
                catch (Exception ex)
                {
                    LogError($"Error registering recurring job '{missingJob}'.", ex);
                }
            }
        }

        private static void RunMissedJobsOnStartup(Database database, Dictionary<string, string> schedules, int lookbackDays)
        {
            var recurringJobs = JobStorage.Current.GetConnection().GetRecurringJobs();
            if (recurringJobs == null) return;

            foreach (var recurringJob in recurringJobs)
            {
                try
                {
                    if (!ID.IsID(recurringJob.Id)) continue;
                    var itemId = recurringJob.Id;
                    if (!schedules.ContainsKey(itemId)) continue;

                    var scheduleItem = new ScheduleItem(database.GetItem(itemId));
                    if (ShouldFireCatchUp(recurringJob.Cron, scheduleItem.LastRun, lookbackDays))
                    {
                        LogMessage($"Running missed job {itemId}.");
                        StartJob(itemId);
                    }
                }
                catch (Exception ex)
                {
                    LogError($"Error processing missed job '{recurringJob?.Id}' on startup.", ex);
                }
            }
        }

        // Decides whether a missed job should be caught up on startup using a
        // hybrid frequency-aware window:
        //
        //   Frequent jobs (sub-daily, e.g. every 5 min or hourly):
        //     Only fire if the miss is within one interval of now. If the next
        //     slot has already passed too, skip — the following run is imminent.
        //
        //   Infrequent jobs (daily or longer, e.g. daily at 09:00 or weekly):
        //     Fire if the miss falls within lookbackDays. A weekly job down for
        //     3 weeks should still catch up rather than waiting another full week.
        //
        // Examples (lookbackDays = 30):
        //   Every 5 min — down 2 h   → skips  (sub-daily; next slot already past)
        //   Hourly      — down 6 h   → skips  (sub-daily; next slot already past)
        //   Daily 09:00 — down 36 h  → fires  (infrequent; 36 h < 30 days)
        //   Every Sat   — down 3 wks → fires  (infrequent; 3 wks < 30 days)
        //   Every Sat   — down 6 wks → skips  (infrequent; 6 wks > 30 days)
        private static bool ShouldFireCatchUp(string cron, DateTime lastRun, int lookbackDays)
        {
            if (lastRun <= DateTime.MinValue || string.IsNullOrEmpty(cron))
                return false;

            var cronExpression = Cronos.CronExpression.Parse(cron);
            var lastRunUtc = DateTime.SpecifyKind(lastRun, DateTimeKind.Utc);
            var expectedRun = cronExpression.GetNextOccurrence(lastRunUtc, TimeZoneInfo.Local);

            if (!expectedRun.HasValue || expectedRun.Value >= DateTime.UtcNow)
                return false;

            var nextAfterExpected = cronExpression.GetNextOccurrence(expectedRun.Value, TimeZoneInfo.Local);
            var intervalToNext = nextAfterExpected.HasValue
                ? nextAfterExpected.Value - expectedRun.Value
                : TimeSpan.FromDays(lookbackDays);

            var isInfrequent = intervalToNext >= TimeSpan.FromDays(1);
            return isInfrequent
                ? DateTime.UtcNow - expectedRun.Value <= TimeSpan.FromDays(lookbackDays)
                : !nextAfterExpected.HasValue || nextAfterExpected.Value > DateTime.UtcNow;
        }

        private static void StartJob(string itemId)
        {
            var jobName = $"{nameof(PrecisionScheduler)}-{itemId}";
            var jobOptions = new DefaultJobOptions(jobName, "scheduling", "scheduler",
                Activator.CreateInstance(typeof(JobRunner)), "Run", new object[] { ID.Parse(itemId) });
            JobManager.Start(jobOptions);
        }

        public static void RunSchedule(ID itemId)
        {
            var database = ServiceLocator.ServiceProvider.GetRequiredService<BaseFactory>().GetDatabase("master", true);
            var item = database.GetItem(itemId);

            if (item == null)
            {
                LogMessage($"Removing background job for {itemId}.");
                RecurringJob.RemoveIfExists(itemId.ToString());
                return;
            }

            var jobName = $"{nameof(PrecisionScheduler)}-{itemId}";
            var runningJob = JobManager.GetJob(jobName);
            if (runningJob != null && runningJob.Status.State == JobState.Running)
            {
                LogMessage($"Background job for {itemId} is already running.");
                return;
            }

            LogMessage($"Running background job for {itemId}.");
            StartJob(itemId.ToString());
        }

        private static string GetSchedule(Item item)
        {
            var schedule = item.Fields[ScheduleFieldIDs.Schedule].Value;
            if (string.IsNullOrEmpty(schedule)) return string.Empty;

            if (Regex.IsMatch(schedule, @"^(((\d+,)+\d+|(\d+|\*(\/|-)\d+)|\d+|\*)\s?){5,7}$", RegexOptions.Compiled))
                return schedule;

            var recurrence = new Recurrence(schedule);
            if (recurrence.Days == DaysOfWeek.None ||
                recurrence.Interval == TimeSpan.Zero ||
                recurrence.InRange(DateTime.UtcNow) != true) return string.Empty;

            return GenerateMultiDayCronExpression(recurrence.Interval, ParseDays((int)recurrence.Days).ToList());
        }

        private static string GenerateMultiDayCronExpression(TimeSpan runTime, List<DayOfWeek> daysToRun)
        {
            var castedDaysToRun = daysToRun.Cast<int>().ToList();
            return $"{ParseCronTimeSpan(runTime)} * * {ParseMultiDaysList(castedDaysToRun)}";
        }

        private static string ParseCronTimeSpan(TimeSpan timeSpan)
        {
            if (timeSpan.Days > 0)
                return $"{timeSpan.Minutes} {timeSpan.Hours}";       // At HH:mm every day.
            if (timeSpan.Hours > 0)
                return $"{timeSpan.Minutes} */{timeSpan.Hours}";     // At m past the hour, every h hours.
            if (timeSpan.Minutes > 0)
                return $"*/{timeSpan.Minutes} *";                     // Every m minutes.

            return "*/30 *";
        }

        private static string ParseMultiDaysList(List<int> daysToRun)
        {
            if (daysToRun.Any() && daysToRun.Count == 7) return "*";
            return string.Join(",", daysToRun);
        }

        private static List<DayOfWeek> ParseDays(int days)
        {
            var daysOfWeek = new List<DayOfWeek>();
            if (days <= 0) return daysOfWeek;

            if (MainUtil.IsBitSet((int)DaysOfWeek.Sunday, days))    daysOfWeek.Add(DayOfWeek.Sunday);
            if (MainUtil.IsBitSet((int)DaysOfWeek.Monday, days))    daysOfWeek.Add(DayOfWeek.Monday);
            if (MainUtil.IsBitSet((int)DaysOfWeek.Tuesday, days))   daysOfWeek.Add(DayOfWeek.Tuesday);
            if (MainUtil.IsBitSet((int)DaysOfWeek.Wednesday, days)) daysOfWeek.Add(DayOfWeek.Wednesday);
            if (MainUtil.IsBitSet((int)DaysOfWeek.Thursday, days))  daysOfWeek.Add(DayOfWeek.Thursday);
            if (MainUtil.IsBitSet((int)DaysOfWeek.Friday, days))    daysOfWeek.Add(DayOfWeek.Friday);
            if (MainUtil.IsBitSet((int)DaysOfWeek.Saturday, days))  daysOfWeek.Add(DayOfWeek.Saturday);

            return daysOfWeek;
        }
    }

    public class JobRunner
    {
        public void Run(ID itemId)
        {
            var database = ServiceLocator.ServiceProvider.GetRequiredService<BaseFactory>().GetDatabase("master", true);
            var item = database.GetItem(itemId);
            if (item == null) return;

            var scheduleItem = new ScheduleItem(item);
            scheduleItem.Execute();
        }
    }
}
