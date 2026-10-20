# DBA Change Audit — setup and operations

## Scope

Reads SQL01 schema events, SSDT_SA master/PRs and Jira AllReleases. Writes only central monitoring history, local caches and IIS JSON. It never deploys captured SQL, modifies production triggers/indexes, writes Git, or posts/approves Jira records.

**Today only means dashboard filtering in SAST (UTC+02:00).** Older central evidence remains stored. No cleanup job is supplied and source retention is untouched. Agree retention/backups after measuring volume; full evidence snapshots can be substantial.

## 1. Host prerequisites

- Central: `HSB-SENTRY-SQL`, database `DBA_ChangeAudit`; SQL Server 2016+ and compatibility level 130+.
- IIS: `HSB-SENTRY-APP1`, Static Content and Windows Authentication.
- Collector: Windows PowerShell 5.1 (tested) with Microsoft ScriptDom supporting `TSql160Parser`. Set `scriptDomPath` to the installed DLL; the tested path is supplied for SSMS 20.
- SQL execution identity: `HOLLYWOODBETS\SentryOne`.
- External read identity: `HOLLYWOODBETS\DouglasN`, using separate Azure DevOps/Jira API credentials. Windows authentication to SQL does not authenticate these cloud APIs.
- Valid trusted SQL TLS certificates and outbound HTTPS to dev.azure.com and betsoftware.atlassian.net. Certificate validation is enabled.
- Execute approved/signed scripts under the organization's script policy; the provided Agent job does not alter it.

## 2. Source SQL access and cost

SentryOne needs SELECT on `DBA.dbo.__schema_change_tracking` and metadata visibility for its indexes. Database access and suitable VIEW DEFINITION permissions in monitored user databases support trigger-coverage checks. Invisible/inaccessible metadata reports Unknown or GapOrMetadataHidden, not healthy.

Run `sql/000_InspectExistingTracking.sql` on SQL01. The supplied table DDL has no declared index. By default, the collector pauses if no enabled, unfiltered index starts with LogId. It never creates an index. If a DBA measures and accepts existing read cost, explicitly set `allowUnindexedSourceRead` true; otherwise address source indexing through the normal RAB process outside this monitor.

Reads are bounded to 500 new IDs plus 500 rotating reconciliation IDs per run, with short timeouts and READ COMMITTED. TOP WITH TIES exposes duplicate IDs at a page boundary and the collector stops on duplicates/conflicts. Very large SQL text can still create a large batch: row limits are not byte limits.

The reconciliation lane walks all retained IDs to recover late commits below the newest-ID cursor. Source retention must exceed outages, backlog and a full reconciliation cycle. Deleted-before-collection events are unrecoverable. “Display today” does not establish source retention; confirm that separately.

The configured source-generation GUID identifies this history. Table fingerprint changes, falling maximum ID or source-hash conflicts stop collection. Investigate reset/restore/purge before assigning a new generation. Some restores retain metadata and maximum ID; differences appear only when affected rows are revisited. This is not a tamper-proof audit against privileged administrators.

## 3. Central files and schema

Have an authorized DBA run `sql/001_CreateChangeAudit.sql` on HSB-SENTRY-SQL. It creates central storage only and is rerunnable for this initial schema. SentryOne's server login must already exist for its explicit EXECUTE grants to be applied. Verify grants afterwards.

Tables: `AuditRun`, `SourceState`, `ChangeEvent`, `EvidenceSnapshot`, and `Assessment`. Event inserts and cursor updates commit together. Original events are never updated by the collector; assessments are appended. API snapshots include run configuration and evidence. The collector receives explicit stored-procedure EXECUTE permissions, not direct UPDATE/DELETE access to evidence tables.

Copy `powershell`, `config` and `sql` to `E:\DBA\ChangeAudit`, or change configured paths. Create private `secrets` and `cache` directories accessible only to SentryOne and authorized DBA administrators. Keep both outside IIS and Git.

## 4. API credential setup

As SentryOne **on the execution host**, run:

```powershell
.\powershell\Initialize-AuditCredentials.ps1 -Path E:\DBA\ChangeAudit\secrets\api-credentials.xml
```

Enter existing external credentials obtained through the organization's normal process:

- Azure DevOps PAT with Code Read for SSDT_SA; username is a label, password field is the PAT.
- Jira account email and API token with access to releases, relevant comments and history; these are not Windows credentials.

The script creates a DPAPI-encrypted file tied to the execution Windows identity and host. Do not create it as DouglasN and expect SentryOne to decrypt it. Ensure the account profile is available when Agent runs. Keep the directory ACL restricted. For rotation, create a new file, update `credentialPath`, test, then retire the old file under your credential process.

This adapter supports Azure PAT and Jira basic email/API-token authentication against the tenant URL. If policy requires OAuth or Jira scoped-token gateway URLs, change the authentication adapter before use. No browser cookies are extracted and no tokens are created by the tool.

## 5. Connection report and manual approval review

```powershell
.\powershell\Test-AuditConnections.ps1 -ConfigPath E:\DBA\ChangeAudit\config\target.json -ReportPath E:\DBA\ChangeAudit\connection-report.json
```

This read-only check reports source/central access, master ref, saved Jira JQL, field IDs and approver IDs from the two inspected sample releases. It does not grant access or automatically authorize observed approvers.

Resolve ambiguous custom-field labels by populating `rabSource.fieldMappings` with verified IDs. Missing approver fields are permitted and shown as Not recorded.

**Updated requirement, 2026-09-16:** there is no approver allowlist, account authorization check, approval-text classification, or automated approval-timing verdict. The dashboard displays names from RAB Approver/RAB Approvers and raw comment authors/text/timestamps. A DBA decides whether the approval is valid and preceded the change.

“Linked — verify approval” and “Evidence linked” mean the technical release evidence matches. They never certify authorization. Prior stored approval decisions remain historical evidence; legacy statuses are labelled for manual verification until fresh assessments are collected.

## 6. IIS

Copy only `wwwroot` into an IIS site/application, for example `D:\Sites\ChangeAudit`. Create the data directory and a narrowly scoped share `\\HSB-SENTRY-APP1\ChangeAuditData` pointing to it. SentryOne needs share and NTFS write permission there; IIS needs read permission. Set `dashboardJsonPath` accordingly.

Configure IIS Windows Authentication, disable Anonymous Authentication, and authorize only the DBA group for **all site files including JSON**, which includes captured SQL text. The supplied web.config configures MIME/security/cache headers; it does not guess your DBA group or change server-level authentication. Verify unauthorized requests cannot retrieve the JSON URL.

Production loads `data/change-audit.json` only. `?demo=1` explicitly selects synthetic examples and displays a DEMO banner; omit `data/demo.json` from the production copy if preferred. Missing production data never falls back to demo data.

## 7. Manual canary and monitoring schedule

```powershell
.\powershell\Collect-ChangeAudit.ps1 -ConfigPath E:\DBA\ChangeAudit\config\target.json
```

Run as SentryOne. Initial indexing can take multiple runs: master SQL files are cached by immutable blob/content hash with a per-run download budget. Exact database/root-folder names map automatically; configure `databaseFolderMappings` for verified exceptions. Missing mappings stay Unknown.

Measure source query time, total run duration, API traffic and central storage growth. Five minutes is polling cadence, not a guaranteed completion SLA. Budgeted cold indexing and thousands of releases can take longer. Agent avoids concurrent instances; a central session application lock also blocks overlapping collectors.

After canary validation, edit `sql/002_CreateCollectorJob.sql` for an existing CmdExec proxy running SentryOne, unless SQL Agent itself runs as that identity. The script creates the job disabled and refuses to overwrite an existing job. Set `scheduledCollectionEnabled` true and enable the monitoring job through normal SQL Agent administration when ready.

## Matching and completeness limits

| Evidence | Implementation |
|---|---|
| Current master | Pinned commit; statement or module-definition comparison using ScriptDom. Safe whitespace/comments and CREATE/ALTER module variants normalize; literals and identifier case are preserved. |
| Unsupported SQL | Dynamic SQL, SQLCMD, implicit schemas, unsupported/mixed batches and differing session contexts require review. |
| Tables/drops | Desired-state table files or missing files do not prove ALTER/DROP operations; matching migration evidence is required. Unsupported PR deletions leave release evidence incomplete. |
| RAB linkage | Reads SA PR links in dedicated field, description and deployment instructions. Object-name mentions without PR links become review candidates. |
| Release linkage | Matching PR artifact and target scope/window. Approver names and comments are displayed; approval validity/timing and authorization are checked by the DBA. |
| Scope | Explicit `Server: <name> ... DB: <database>` within one segment. Other layouts, missing dates and typos require review; no fuzzy server aliases are enabled. |
| Missing evidence | “No RAB matched” means no matching evidence in accessible configured release/PR/text scope, not proof no RAB exists anywhere. SQL attachments, screenshots and other repositories are not automatically parsed. |
| API limits | Paginated Jira search/comments/history and PR changes have budgets. Caps, failures, unknown fields and unsupported evidence stay Unknown. Confirm account visibility across projects and restricted comments. |
| Caching | Master ref fetched each run; SQL text cached at immutable IDs/hashes. Completed PR metadata cached up to 24 hours, active PR metadata five minutes; see configured limits. |
| Grace | Fifteen minutes delays technical exception labels only. The tool makes no approval-timing decision. |

Current master matching does not establish historical deployment provenance. PR source/merge content is checked separately, and run evidence is retained. No automatic remediation, change deployment, notification posting, approval or review write-back is included.

## Testing

From the pack directory, under your approved script policy:

```powershell
.\tests\Test-Audit.ps1 -ScriptDomPath 'C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\Extensions\Application\Microsoft.SqlServer.TransactSql.ScriptDom.dll'
.\tests\Test-Sources.ps1
.\tests\Test-Collection.ps1
```

Core, mocked adapter and mocked collection checks pass under Windows PowerShell 5.1 and PowerShell 7. Tests cover SQL identity/literals/context, time boundaries, manual approver/comment display, scope isolation, verdict independence, atomic JSON, pagination/stalls, field resolution, immutable cache warmup, late-commit recovery, replay, failed cursor commits and source reset detection. SQL scripts parse through ScriptDom. Browser demo checks cover summary counts, search and the SQL-evidence dialog.

**Still requires live canary:** actual SQL procedure execution/permissions, source performance and retention, API credential/field access, share/IIS ACLs, and end-to-end real event comparison. Offline tests do not establish production correctness.

Use existing authorized test fixtures/releases to verify all controls and failure cases. The tool itself does not create test changes on SQL01 or write test releases to Jira/Git.

## Operations

Inspect dashboard Source Health, `dbo.AuditRun.HealthJson`, and `dbo.SourceState` cursor progress. Stale/wrong-day exports show warnings and hide yesterday's rows. Prior assessments may remain visible during an outage; interpret them together with source health. A fatal process exit may leave a Running run until the next export; stale-data detection remains active.

Use existing SQL Agent failure notifications/job monitoring. This version sends no email. Stop monitoring by disabling its Agent job and setting `scheduledCollectionEnabled` false. History remains; no source rollback is necessary.

## References

- [Jira enhanced issue search](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/)
- [Jira fields](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-fields/)
- [Jira comments](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-comments/)
- [Azure DevOps items](https://learn.microsoft.com/en-us/rest/api/azure/devops/git/items/list?view=azure-devops-rest-7.1)
- [Microsoft ScriptDom](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.transactsql.scriptdom.tsql160parser?view=sql-transactsql-161)
