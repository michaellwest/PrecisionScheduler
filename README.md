# PrecisionScheduler for Sitecore

PrecisionScheduler for Sitecore is a drop-in replacement for the standard Task Scheduling found in Sitecore. Check out [this article](https://michaellwest.blogspot.com/2022/08/replacement-task-scheduler-for-sitecore.html) for more details.

## Required Dependencies

* Hangfire.AspNet
* Hangfire.Core
* Hangfire.MemoryStorage

## Configuration

There really isn't much for you to do. Your existing schedules should "just work". If you would like to make use of more advanced scheduling, use a cron schedule format in the _Schedule_ field of a scheduled task.
