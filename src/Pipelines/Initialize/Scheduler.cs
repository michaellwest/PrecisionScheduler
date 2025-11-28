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
        public string MisfireBehavior { get; set; } = "Relaxed";

        private static void LogMessage(string message)
        {
            Log.Info($"[PrecisionScheduler] {message}", nameof(Scheduler));
        }

        public override void Process(InitializeArgs args)
        {
            var app = args.App;

            app.UseHangfireAspNet(() =>
            {
                GlobalConfiguration.Configuration.UseMemoryStorage();
                return new[] { new BackgroundJobServer() };
            });

            LogMessage("Starting up precision scheduler.");
            var misfireHandlingMode = MisfireHandlingMode.Relaxed;
            switch (MisfireBehavior)
            {
                case var behavior when string.Equals(behavior, "Ignore", StringComparison.InvariantCultureIgnoreCase):
                    misfireHandlingMode = MisfireHandlingMode.Ignorable;
                    break;
                case var behavior when string.Equals(behavior, "FireAll", StringComparison.InvariantCultureIgnoreCase):
                    misfireHandlingMode = MisfireHandlingMode.Strict;
                    break;
                case var behavior when string.Equals(behavior, "FireOnce", StringComparison.InvariantCultureIgnoreCase):
                    break;
                case var behavior when string.IsNullOrEmpty(behavior):
                default:
                    misfireHandlingMode = MisfireHandlingMode.Relaxed;
                    break;
            }

            var recurringJobOptions = new RecurringJobOptions
            {
                TimeZone = TimeZoneInfo.Local,
                MisfireHandling = misfireHandlingMode
            };
            BackgroundJob.Schedule(() => Initialize(RefreshSchedule, recurringJobOptions), TimeSpan.FromSeconds(StartupDelaySeconds));
        }

        private static string GenerateMultiDayCronExpression(TimeSpan runTime, List<DayOfWeek> daysToRun)
        {
            var castedDaysToRun = daysToRun.Cast<int>().ToList();
            return $"{ParseCronTimeSpan(runTime)} * * {ParseMultiDaysList(castedDaysToRun)}";
        }

        private static string ParseCronTimeSpan(TimeSpan timeSpan)
        {
            if (timeSpan.Days > 0)
            {
                //At HH:mm every day.
                return $"{timeSpan.Minutes} {timeSpan.Hours}";
            }
            else if (timeSpan.Hours > 0)
            {
                //At m minutes past the hour, every h hours.
                return $"{timeSpan.Minutes} */{timeSpan.Hours}";
            }
            else if (timeSpan.Minutes > 0)
            {
                //Every m minutes.
                return $"*/{timeSpan.Minutes} *";
            }

            return $"*/30 *";
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

            if (MainUtil.IsBitSet((int)DaysOfWeek.Sunday, days))
            {
                daysOfWeek.Add(DayOfWeek.Sunday);
            }
            if (MainUtil.IsBitSet((int)DaysOfWeek.Monday, days))
            {
                daysOfWeek.Add(DayOfWeek.Monday);
            }
            if (MainUtil.IsBitSet((int)DaysOfWeek.Tuesday, days))
            {
                daysOfWeek.Add(DayOfWeek.Tuesday);
            }
            if (MainUtil.IsBitSet((int)DaysOfWeek.Wednesday, days))
            {
                daysOfWeek.Add(DayOfWeek.Wednesday);
            }
            if (MainUtil.IsBitSet((int)DaysOfWeek.Thursday, days))
            {
                daysOfWeek.Add(DayOfWeek.Thursday);
            }
            if (MainUtil.IsBitSet((int)DaysOfWeek.Friday, days))
            {
                daysOfWeek.Add(DayOfWeek.Friday);
            }
            if (MainUtil.IsBitSet((int)DaysOfWeek.Saturday, days))
            {
                daysOfWeek.Add(DayOfWeek.Saturday);
            }

            return daysOfWeek;
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
            var scheduleItem = new ScheduleItem(item);

            var jobOptions = new DefaultJobOptions(jobName, "scheduling", "scheduler", Activator.CreateInstance(typeof(JobRunner)), "Run", new object[] { ID.Parse(itemId) });
            JobManager.Start(jobOptions);
        }

        public static void Initialize(string refreshSchedule, RecurringJobOptions jobOptions)
        {
            ManageJobs(true);
            RecurringJob.AddOrUpdate(nameof(ManageJobs), () => ManageJobs(false), refreshSchedule, jobOptions);
        }

        public static void ManageJobs(bool isStartup)
        {
            var database = ServiceLocator.ServiceProvider.GetRequiredService<BaseFactory>().GetDatabase(SCHEDULE_DATABASE, true);
            var descendants = database.SelectItems($"/sitecore/system/tasks/schedules//*[@@templateid='{TemplateIDs.Schedule}']");
            var schedules = new Dictionary<string, string>();

            foreach (var item in descendants)
            {
                if (item.TemplateID != TemplateIDs.Schedule) continue;
                var itemId = item.ID.ToString();
                var schedule = GetSchedule(item);
                if (string.IsNullOrEmpty(schedule)) continue;
                schedules.Add(itemId, schedule);
            }

            var jobs = JobStorage.Current.GetConnection().GetRecurringJobs();
            var existingJobs = new List<string>();
            foreach (var job in jobs)
            {
                if (!ID.IsID(job.Id)) continue;
                var itemId = job.Id;

                if (!schedules.ContainsKey(itemId))
                {
                    LogMessage($"Removing {itemId} from recurring schedule.");
                    RecurringJob.RemoveIfExists(itemId);
                    continue;
                }

                var item = database.GetItem(itemId);
                var schedule = GetSchedule(item);
                if (string.IsNullOrEmpty(schedule))
                {
                    LogMessage($"Removing {itemId} from recurring schedule with invalid expression.");
                    RecurringJob.RemoveIfExists(itemId);
                    continue;
                }

                if (!string.Equals(job.Cron, schedule, StringComparison.InvariantCultureIgnoreCase))
                {
                    LogMessage($"Updating {itemId} with a new schedule '{schedule}'.");
                    RecurringJob.AddOrUpdate($"{itemId}", () => RunSchedule(ID.Parse(itemId)), schedule, TimeZoneInfo.Local);
                }

                existingJobs.Add(itemId);
            }

            var missingJobs = schedules.Keys.Except(existingJobs);
            foreach (var missingJob in missingJobs)
            {
                var itemId = missingJob;
                var item = database.GetItem(itemId);
                var schedule = GetSchedule(item);

                LogMessage($"Registering recurring job for {itemId} with schedule '{schedule}'.");
                RecurringJob.AddOrUpdate($"{itemId}", () => RunSchedule(ID.Parse(itemId)), schedule, TimeZoneInfo.Local);
            }

            if (isStartup)
            {
                var recurringJobs = JobStorage.Current.GetConnection().GetRecurringJobs();
                if (recurringJobs == null) return;

                foreach (var recurringJob in recurringJobs)
                {
                    if (!ID.IsID(recurringJob.Id)) continue;
                    var itemId = recurringJob.Id;

                    if (!schedules.ContainsKey(itemId)) continue;
                    var item = database.GetItem(itemId);
                    var scheduleItem = new ScheduleItem(item);

                    var missedLastRun = recurringJob.NextExecution - scheduleItem.LastRun > TimeSpan.FromHours(24);
                    if (missedLastRun)
                    {
                        LogMessage($"Running missed job {itemId}.");
                        var jobName = $"{nameof(PrecisionScheduler)}-{itemId}";

                        var jobOptions = new DefaultJobOptions(jobName, "scheduling", "scheduler", Activator.CreateInstance(typeof(JobRunner)), "Run", new object[] { ID.Parse(itemId) });
                        JobManager.Start(jobOptions);
                    }
                }
            }
        }

        private static string GetSchedule(Item item)
        {
            var schedule = item.Fields[ScheduleFieldIDs.Schedule].Value;
            if (string.IsNullOrEmpty(schedule)) return string.Empty;

            if (Regex.IsMatch(schedule, @"^(((\d+,)+\d+|(\d+|\*(\/|-)\d+)|\d+|\*)\s?){5,7}$", RegexOptions.Compiled))
            {
                return schedule;
            }

            var recurrence = new Recurrence(schedule);
            if (recurrence.Days == DaysOfWeek.None ||
                recurrence.Interval == TimeSpan.Zero ||
                recurrence.InRange(DateTime.UtcNow) != true) return string.Empty;

            return GenerateMultiDayCronExpression(recurrence.Interval, ParseDays((int)recurrence.Days).ToList());
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
