# PrecisionScheduler for Sitecore

PrecisionScheduler for Sitecore is a drop-in replacement for the standard Task Scheduling found in Sitecore. Check out [this article](https://michaellwest.blogspot.com/2022/08/replacement-task-scheduler-for-sitecore.html) for more details.

## Required Dependencies

* Hangfire.AspNet
* Hangfire.Core
* Hangfire.MemoryStorage
* Sitecore.Kernel
* Sitecore.Owin

## Configuration

There really isn't much for you to do. Your existing schedules should "just work". If you would like to make use of more advanced scheduling, use a cron schedule format in the _Schedule_ field of a scheduled task.

### NuGet PackageReference

If you are installing using `PackageReference` instead of `packages.config` you'll want to either copy over the configuration files include in this repo or create your own.

```xml
<?xml version="1.0" encoding="utf-8" ?>
<configuration xmlns:patch="http://www.sitecore.net/xmlconfig/" xmlns:set="http://www.sitecore.net/xmlconfig/set/" xmlns:role="http://www.sitecore.net/xmlconfig/role/">
  <sitecore role:require="Standalone or ContentManagement">
    <pipelines>
      <owin.initialize>
        <processor type="PrecisionScheduler.Pipelines.Initialize.Scheduler, PrecisionsScheduler">
          <StartupDelaySeconds>30</StartupDelaySeconds>
          <RefreshSchedule>*/2 * * * *</RefreshSchedule>
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