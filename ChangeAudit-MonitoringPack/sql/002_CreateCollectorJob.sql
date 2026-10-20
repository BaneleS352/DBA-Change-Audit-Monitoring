/* CENTRAL SQL AGENT ONLY. Creates the monitoring job DISABLED for setup/canary.
   No production changes are deployed by this job. Configure a CmdExec proxy for
   HOLLYWOODBETS\SentryOne unless SQL Agent itself runs as that account. */
USE msdb;
GO
DECLARE @JobName sysname=N'DBA - Change Audit Monitor';
DECLARE @ScheduleName sysname=N'DBA - Change Audit - Every 5 Minutes';
DECLARE @ProxyName sysname=NULL; -- Existing CmdExec proxy for HOLLYWOODBETS\SentryOne, if required.
DECLARE @Command nvarchar(max)=N'powershell.exe -NoProfile -File "E:\DBA\ChangeAudit\powershell\Collect-ChangeAudit.ps1" -ConfigPath "E:\DBA\ChangeAudit\config\target.json" -Scheduled';
DECLARE @JobId uniqueidentifier;
IF EXISTS(SELECT 1 FROM dbo.sysjobs WHERE name=@JobName)
    THROW 51000, 'Job already exists. Review its configuration rather than overwriting it.', 1;
EXEC dbo.sp_add_job @job_name=@JobName,@enabled=0,
    @description=N'Reads SQL01 schema events, Azure DevOps master and Jira releases. Writes only central monitoring evidence and IIS JSON.',@job_id=@JobId OUTPUT;
EXEC dbo.sp_add_jobstep @job_id=@JobId,@step_name=N'Collect and reconcile evidence',@subsystem=N'CmdExec',
    @command=@Command,@proxy_name=@ProxyName,@retry_attempts=0,@on_success_action=1,@on_fail_action=2;
EXEC dbo.sp_add_jobschedule @job_id=@JobId,@name=@ScheduleName,@enabled=1,
    @freq_type=4,@freq_interval=1,@freq_subday_type=4,@freq_subday_interval=5,@active_start_time=000000;
EXEC dbo.sp_add_jobserver @job_id=@JobId;
GO
