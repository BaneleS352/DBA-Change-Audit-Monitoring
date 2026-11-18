# DBA Change Audit — setup and operations

## Scope

The current phase reads schema change events from `HSB-SYX20-SQL01.DBA.dbo.__schema_change_tracking`, retains source evidence centrally, and compares events whose `DatabaseName` is `Affiliates` with SQL files in the root of Affiliates.Database on Azure DevOps `main`. RAB/Jira lookup is deferred. The collector only reads the source database and Azure DevOps; it never executes captured SQL or writes to Git.

The dashboard shows today's events in South African time. Older events remain in central history. This is an investigative aid, not a tamper-proof audit against privileged administrators and not proof of approval or deployment history.

## Prerequisites and permissions

- Central SQL: `HSB-SENTRY-SQL`, database `DBA_ChangeAudit`; SQL Server 2016+ and compatibility level 130+.
- Dashboard: IIS on `HSB-SENTRY-APP1`, Windows Authentication, and DBA-only access to all site files including the JSON export.
- Collector: Windows PowerShell 5.1 and Microsoft ScriptDom with `TSql160Parser`.
- Execution identity: `HOLLYWOODBETS\SentryOne`, with source table SELECT, required SQL metadata visibility, central procedure EXECUTE rights, and private cache/export write access.
- API: Azure DevOps PAT with Code Read on the configured repository, outbound HTTPS to `dev.azure.com`, and a trusted TLS certificate.

Inspect the source using `sql/000_InspectExistingTracking.sql`. Confirm the table columns, source indexes, event volume, retention, and trigger coverage. The collector pauses on an unindexed LogId source by default and never creates an index. Source retention must cover outages and collector backlog.

## Install central storage and files

An authorized DBA runs `sql/001_CreateChangeAudit.sql` on `HSB-SENTRY-SQL`. It creates central history tables and procedures. The SentryOne login must already exist for the script's EXECUTE grants. Confirm the grants and the changed `usp_ReadToday` and `usp_DashboardJson` database filter parameters are installed before collection.

Copy `powershell`, `config`, and `sql` to `E:\DBA\ChangeAudit` or adjust the configured paths. Keep the `secrets` and `cache` directories outside IIS and Git, with ACLs restricted to SentryOne and authorized administrators.

## PAT setup and connection check

Follow [CREDENTIAL_SETUP.md](CREDENTIAL_SETUP.md) to save the PAT securely on the collector host as SentryOne. Never place it in `target.json`, source code, reports, job output, or the IIS site. The scheduled job remains disabled until the setup and canary are approved.

Run the read-only report under SentryOne:

```powershell
E:\DBA\ChangeAudit\powershell\Test-AuditConnections.ps1 -ConfigPath E:\DBA\ChangeAudit\config\target.json -ReportPath E:\DBA\ChangeAudit\connection-report.json
```

Review SQL permissions, Azure repository identity, `refs/heads/main`, and errors in the report. Verify the repository tree actually contains the Affiliates deployable SQL definitions at root. The current config maps `Affiliates` to `/`; change `databaseFolderMappings` to a verified SQL folder if needed. An absent or incomplete mapped scope must remain Unknown, not be interpreted as a reliable missing-definition result.

## Dashboard and canary

Copy `wwwroot` to the IIS site and configure `dashboardJsonPath` to its `data/change-audit.json`. SentryOne needs share and NTFS write rights; IIS needs read rights. Authorize only the DBA group for the site and JSON. Verify unauthorized requests cannot read the JSON, which contains captured SQL text.

Run manually as SentryOne:

```powershell
E:\DBA\ChangeAudit\powershell\Collect-ChangeAudit.ps1 -ConfigPath E:\DBA\ChangeAudit\config\target.json
```

Cold indexing is bounded by `repositoryFilesPerRun` and may need multiple runs; cached SQL is keyed by immutable blob IDs. Confirm an event, exact commit, result, captured SQL, and health state using existing authorized data. Measure run duration, SQL read cost, API use, backlog recovery, and central storage before enabling the schedule.

The SQL Agent job template is disabled by default. Configure an appropriate existing CmdExec proxy and keep `scheduledCollectionEnabled` false until the canary, permissions, and IIS ACLs are accepted. Five-minute polling is not a completion SLA. The central application lock prevents overlapping runs.

## Comparison behavior and limits

- Repository ref is fetched each run; the exact commit is recorded with comparison evidence.
- SQL statements are parsed with ScriptDom and compared by database, schema, object, operation, and content. Safe whitespace/comment and supported module CREATE/ALTER variants normalize; literals and identifier case remain significant.
- Unsupported syntax, SQLCMD, implicit schemas, ambiguous or mixed batches, context mismatches, incomplete repository scans, and unmapped scopes remain Needs review or Unknown.
- A match means the captured change matches SQL content at the pinned current `main` commit. It does not establish historical deployment provenance or approval.
- ALTER TABLE and DROP may require migration evidence; a desired-state definition or absent file alone is insufficient.
- Only the `Affiliates` database is displayed and assessed in this phase. Source rows for other databases are still retained centrally but are not included in this dashboard view.
- The 15-minute grace period delays technical exception labels. No RAB lookup, approval validation, remediation, deployment, notification, or review write-back is active in this phase.

## Operations

Review dashboard source/repository health, `dbo.AuditRun.HealthJson`, and `dbo.SourceState` progress. Stale exports warn; prior assessments remain historical and must be read with current health. Investigate SQL/API failures and source reset/hash conflicts before relying on results.

Rotate credentials by creating a new DPAPI file as SentryOne on the collector host, updating `credentialPath`, verifying access, and retiring the old file under the credential process. Stop monitoring by disabling the SQL Agent job and setting `scheduledCollectionEnabled` false. Central evidence remains retained; no source rollback is needed.

## Validation boundary

Offline tests in the pack predate this repository-only change and have not been updated or run for this implementation. Live validation still requires actual SQL procedure execution/permissions, PAT access, repository root mapping confirmation, source performance/retention, IIS/share ACLs, and an end-to-end canary.
