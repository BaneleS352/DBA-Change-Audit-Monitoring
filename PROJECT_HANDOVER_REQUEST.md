# Project request and handover: DBA Change Audit

**Prepared:** 19 October 2026  
**Requested outcome:** Take ownership of the existing implementation, complete technical review and live validation, and deliver a supported monitoring service for the DBA team.  
**Current stage:** Implementation and installation pack prepared; offline validation recorded. Production installation and end-to-end operation are not confirmed.

## 1. Request to the receiving team

Please take over the DBA Change Audit project described below. We need a tool that helps DBAs identify database schema changes on `HSB-SYX20-SQL01` that do not match the approved repository branch, do not have matching RAB/release evidence, or need investigation because the evidence is incomplete.

An existing PowerShell, SQL Server and IIS implementation is included. Please review and build on it, validate its behaviour against real accessible data, complete the infrastructure and credential setup, and hand over a supported service with operating documentation. The approach follows the technology used for DBA Morning Checks; any integration with that application still needs to be confirmed.

Please provide an implementation plan, named owners, dependencies, estimated effort and delivery dates after reviewing the pack. No delivery date or production service level has been agreed yet.

## 2. Business purpose

DBAs currently need to reconcile changes made on a SQL Server with source control and release records. This project brings those sources together so a DBA can answer:

- What changed, in which database and schema, when, and under which SQL login?
- Does the captured change match the SQL held in `SSDT_SA` on `master`?
- Is there a corresponding Jira RAB/release with matching technical evidence and deployment scope?
- Who is recorded as the approver, and what comments and timestamps are available for manual verification?
- Are missing results genuine evidence gaps, or is collection incomplete or unavailable?

The tool supports investigation. It does not certify that a change was authorized.

## 3. Confirmed environment and decisions

| Area | Agreed value |
|---|---|
| Monitored SQL Server | `HSB-SYX20-SQL01` |
| Existing event source | `DBA.dbo.__schema_change_tracking` |
| Central SQL host | `HSB-SENTRY-SQL` |
| Central database in implementation | `DBA_ChangeAudit` |
| Dashboard host | `HSB-SENTRY-APP1`, IIS |
| Collector Windows identity | `HOLLYWOODBETS\SentryOne` |
| Existing external-access identity | `HOLLYWOODBETS\DouglasN`; separate API authentication required |
| Repository | [Azure DevOps SSDT_SA]
| Comparison branch | **master** |
| Jira releases | [AllReleases, filter 10528]
| Timezone | South African time, SAST / UTC+02:00 |
| Dashboard period | Today's activity only |
| Historical storage | Retain central evidence; one-day display is not a deletion policy |
| Approval decision | Human DBA review; display names, comments and timestamps |
| Source access | Read-only SQL, repository and Jira access |

The business expectation remains that approval should precede the action. **The final agreed requirement is that the tool does not enforce this rule:** it must not validate approver membership, maintain an approver allowlist, interpret a comment as a valid approval, or automatically decide whether approval was timely. The person checking the dashboard verifies those matters.

## 4. Scope and exclusions

### In scope

1. Collect newly logged DDL events from the existing tracking table.
2. Reconcile retained source events to recover late commits and detect conflicting/replayed source data.
3. Compare captured SQL with a pinned snapshot of `master`, preserving database, schema and object identity.
4. Discover relevant releases in the configured Jira filter and follow links to relevant SSDT_SA PR evidence.
5. Evaluate technical linkage, target server/database and deployment window separately from manual approval review.
6. Present independent repository and RAB results, recorded approvers, captured SQL and source links.
7. Retain source events, assessments and evidence centrally, with collection-health reporting.
8. Provide installation, credential rotation, operation, troubleshooting and support documentation.

### Out of scope

- Deploying or executing database changes, including replaying captured SQL.
- Automatically changing production triggers, tables or indexes.
- Writing to Git, creating PRs, merging code, or posting/updating/approving Jira issues.
- Automated approver authorization or approval validity/timing checks.
- Automatic remediation, email notifications, or review write-back in the current pack.
- General DML auditing, server-level security auditing, or DDL event types not captured by the supplied trigger.
- Parsing SQL attachments/screenshots or searching other repositories automatically.

Installation of the monitoring service is required; deployment of application/database changes by this tool is excluded.

## 5. Existing SQL capture mechanism

The requester supplied a database-scoped DDL trigger named `schema_change_tracking`, described as installed across the monitored databases. The supplied example was scripted from `Archive`. Actual coverage and enabled status require verification.

It captures CREATE, ALTER and DROP for:

- Stored procedures.
- Tables.
- Functions.
- Views.

The trigger uses `EVENTDATA()` and inserts database, event type, schema, object name/type, SQL command and login into `[DBA].[dbo].[__schema_change_tracking]`. `EventDate` is populated by a `GETDATE()` default. The monitor consumes this table; it does not replace the trigger.

### Supplied table contract

| Column | SQL type | Notes |
|---|---|---|
| LogId | int IDENTITY(1,1) | NOT NULL; source cursor identifier |
| DatabaseName | varchar(256) | NOT NULL |
| EventType | varchar(50) | NOT NULL |
| SchemaName | varchar(50) | Nullable |
| ObjectName | varchar(256) | NOT NULL |
| ObjectType | varchar(25) | NOT NULL |
| SqlCommand | varchar(max) | NOT NULL |
| EventDate | datetime | NOT NULL; default GETDATE(); interpreted as SAST |
| LoginName | varchar(256) | NOT NULL |

The supplied DDL declares no primary key or index. Verify the actual table before enabling collection. The implementation pauses unindexed `LogId` reads by default. Any source index change must follow the separate normal DBA/RAB process. Existing varchar capture cannot recover Unicode characters already lost at insertion.

Source retention must cover outages, collection backlog and a full reconciliation cycle. Events removed before collection cannot be recovered by the tool. The source is not a tamper-proof audit against privileged administrators.

## 6. Repository comparison requirements

Use `SSDT_SA` on `master`, not another branch. The observed repository ID is `dbb47529-e909-4417-8307-947e4db20598`.

The repository has database-related root folders. The implementation records these 26 observed folders:

`AutoWithdrawals`, `Balance`, `BetGames`, `BetStrike`, `Betting`, `BettingData`, `Client`, `ClientCentral`, `CockroachDb`, `FeedUpdates`, `FicaSelfService`, `HorseRacingIntegration`, `Staging`, `SystemC`, `SyX`, `SyXAudit`, `SyXBonus`, `SyXHorseRacing`, `SyXPlatforms`, `SyXPlugins`, `SyXReporting`, `SyXResultingStore`, `SyXSignalR`, `SyXTote`, `SyXWorker`, `TransformationLayer`.

These are discovery observations, not a verified inventory of live databases. Confirm mappings and distinguish deployable definitions from supporting scripts. Exact database/root names map automatically; verified exceptions belong in configuration.

Comparison must:

- Use SQL identity and content, not just filenames or object-name mentions.
- Include the schema; `/Betting` was observed to include both `dbo` and `resulting`.
- Pin the master commit used in each assessment and retain evidence of the comparison.
- Normalize safe formatting/comments and supported CREATE/ALTER module variants using ScriptDom, without erasing meaningful literal or identifier differences.
- Leave unsupported SQL, ambiguous identity, dynamic SQL, SQLCMD, implicit schemas, mixed batches and incompatible session context for review.
- Treat ALTER TABLE and DROP carefully: a desired-state definition or an absent file is insufficient proof of the executed operation. Matching migration evidence is required.

A match in current master does not establish that the same artifact was approved or present at the time of execution. Repository match and release-artifact match must remain separate.

## 7. Jira/RAB reconciliation requirements

The saved filter was inspected on 15 September 2026 and showed:

```text
issuetype = Release ORDER BY created DESC
```

The UI showed more than 1,000 results across projects and statuses. Revalidate the saved filter and account visibility at implementation time. Complete pagination is necessary before interpreting absence.

Relevant observed field labels include deployment start (`Date & Time of Deployment`), deployment end (`End Date and Time`), `RAB Approver`, `RAB Approvers`, `Link to Pull Request`, `Link to Release Pipeline`, `Deployment Instructions`, `Environments`, `All Platforms`, and `Release Outcome`. Discover actual custom-field IDs and configure ambiguous mappings. Missing approver fields must not stop collection; display “Not recorded”.

Extract PR links from the dedicated PR field, description and deployment instructions. A release may contain links for SA, LuckyFish and Mozambique, and the dedicated field may contain only a non-SA link. Select relevant PRs using repository identity, not link order or an “SA” label alone.

Technical release linkage checks PR artifact content, explicit target server/database and deployment window. The current parser expects `Server: <name> ... DB: <database>` within a single segment. Other layouts, missing dates and misspelled server names require review. No fuzzy aliases are enabled.

Display recorded approvers and raw comment authors, text and timestamps. Do not equate Jira status Done, release outcome Successful, a populated approver field, or PR reviewer approval with valid prior RAB approval.

### Discovery examples requiring conservative handling

These are observations from 15 September 2026, not current issue assessments:

- [S20C-9455]: SA PR 83261 in description; dedicated PR field empty; end time missing; target text `hsb-syx-sql01` differs from monitored `HSB-SYX20-SQL01`. The PR was Active at inspection.
- [SC-15636]: SA PR 82924 in description but Mozambique PR in dedicated field; start time missing; target `HSB-SXY20-SQL01` differs from monitored server.

Do not silently correct these values. Preserve discrepancies for DBA investigation. Earlier discovery notes discussing automatic approval checks are superseded by the manual-review requirement in this document and the updated runbook.

## 8. Dashboard and assessment requirements

Show today's activity using SAST boundaries, with:

- Time, database, schema/object, event type and executing login.
- Recorded approver name(s), or “Not recorded”.
- Separate repository result, RAB linkage result and overall assessment.
- Search and filters by database and assessment.
- Evidence details: captured SQL, comparison reasons, repository/PR/Jira links, approver names and comment timestamps.
- SQL/repository/Jira health, last export time, incomplete evidence and stale-data warnings.

Overall categories in the implementation are Evidence linked, Repository exception, RAB exception, Both exceptions, Needs review and Pending. “Evidence linked” means a master match plus technical release linkage; it never means “Approved”.

API failures, incomplete scans, unknown mappings and unsupported evidence must not produce confident absence verdicts. “No RAB matched” means no match within the accessible configured evidence scope. The configured 15-minute grace period delays technical exception labels; it is not approval permission.

Yesterday's rows must not be represented as today's results. Production data must not silently fall back to synthetic demo data. The dashboard is read-only; a stored human-review workflow is not included.

## 9. Architecture and implementation supplied

```text
SQL01 DDL tracking table ─┐
SSDT_SA master / PR APIs ─┼─> PowerShell collector on HSB-SENTRY-SQL
Jira filter / issue APIs ─┘       │
                                 ├─> DBA_ChangeAudit: events, runs, evidence, assessments
                                 └─> JSON export share on HSB-SENTRY-APP1 ─> IIS dashboard
```

The pack includes:

| Component | Purpose |
|---|---|
| `sql/000_InspectExistingTracking.sql` | Read-only source inspection |
| `sql/001_CreateChangeAudit.sql` | Central tables and stored procedures |
| `sql/002_CreateCollectorJob.sql` | Disabled five-minute SQL Agent job template |
| `powershell/Collect-ChangeAudit.ps1` | Collection/reconciliation/export runner |
| `Audit.Sql.psm1` | Bounded source reads, source-state checks and persistence |
| `Audit.Core.psm1` | SQL parsing/comparison and manual approval evidence display |
| `Audit.Sources.psm1` | Read-only repository/Jira adapters, pagination and caching |
| `Audit.Reconcile.psm1` | Evidence linkage and independent assessments |
| `Initialize-AuditCredentials.ps1` | Encrypted credential setup |
| `Test-AuditConnections.ps1` | Host/API/field connectivity report |
| `config/target.json` | Environment settings, budgets and mappings |
| `wwwroot` | Static HTML/CSS/JavaScript dashboard and explicit demo data |
| `tests` | Core, mocked API and mocked collection tests |

Central tables are `AuditRun`, `SourceState`, `ChangeEvent`, `EvidenceSnapshot` and `Assessment`. Original events are preserved and assessments appended. Event storage and source cursor updates commit together.

Current defaults include 500 new source IDs plus 500 rotating reconciliation IDs per run, a 100-file repository download budget, bounded Jira/PR pagination, immutable content caching, and a central application lock to prevent overlapping collectors. Limits must be measured and tuned; a five-minute schedule is not a guaranteed five-minute detection SLA. The schedule is disabled by default.

## 10. Hosting, access and credentials

### Hosting and runtime

- SQL Server 2016+ with compatibility level 130+ for central storage, as specified in the current runbook.
- Windows PowerShell 5.1 and Microsoft ScriptDom supporting `TSql160Parser`.
- Default script root `E:\DBA\ChangeAudit`; configurable ScriptDom, cache and credential paths.
- IIS Static Content and Windows Authentication on `HSB-SENTRY-APP1`.
- Default export `\\HSB-SENTRY-APP1\ChangeAuditData\change-audit.json`.
- Trusted SQL TLS certificates and HTTPS connectivity to Azure DevOps and Jira.

### Permissions

- SentryOne: source table SELECT and appropriate metadata visibility for index and trigger coverage checks.
- SentryOne: required central procedure execution permissions and write access to private cache/export locations.
- SQL Agent: an appropriate existing execution identity or CmdExec proxy for SentryOne.
- IIS: read access to dashboard content; DBA-only authenticated access to all files, including exported JSON containing captured SQL.
- Confirm the actual DBA security group, site URL, share/NTFS permissions, service account profile and script execution policy.

### External authentication

The Windows account name and an authenticated browser session do not provide unattended API access. The current adapter requires an Azure DevOps PAT with Code Read, plus Jira email/API token credentials. It uses the Jira tenant URL with email/token authentication; OAuth or scoped-token gateway requirements need adapter review before use.

Tokens are created once and reused until expiry, revocation or rotation. The current tool does not renew them automatically. Assign a credential owner and rotation process.

Save credentials using the supplied initializer **as SentryOne on the collector host**. The encrypted file is tied to that Windows identity and computer. Keep secrets outside Git and IIS and do not include them in the handover message. The Jira token's effective permissions depend on the account/token configuration; read-only application behaviour does not by itself restrict the token's permissions.

## 11. Completed work and validation boundary

The implementation pack, dashboard, configuration, installation scripts and runbook have been prepared. Authenticated browser discovery of the repository and two Jira examples was performed on 15 September 2026.

The recorded 16 September 2026 validation reports:

- 51 core assertions passing.
- 12 mocked API assertions passing.
- 9 mocked collection assertions passing.
- JavaScript/configuration/SQL/PowerShell parsing checks passing.
- Earlier synthetic dashboard checks covering summaries, search and evidence details.

These are **72 recorded offline assertions**, not a fresh October test run or proof of live operation. Tests cover SQL identity/literals/context, time boundaries, manual evidence display, independent verdicts, scope isolation, pagination, cache warmup, replay, late commits and cursor/source-state handling.

The requester reported successfully running a check, but the exact script/output was not identified. Do not treat this as confirmed end-to-end validation.

Still unverified: production SQL procedure execution and permissions, actual source performance/retention, unattended API credentials and field visibility, complete Jira import, IIS/share access controls, and a real-event end-to-end canary.

## 12. Requested delivery work

1. Review the existing code, configuration, tests and documented limitations; rerun validation in the team's environment.
2. Confirm technical ownership, hosting readiness, SQL/IIS prerequisites and permitted authentication approach.
3. Inspect the actual source table, indexes, event volume, retention and trigger coverage. Agree the acceptable read cost before enabling collection.
4. Establish and test credentials under the actual scheduled execution identity.
5. Verify repository/database mappings, Jira fields, filter visibility and pagination completeness. Keep ambiguous scope for manual review.
6. Install central storage, configure the export share and secure IIS content and JSON.
7. Run a manual end-to-end canary using existing authorized evidence; do not introduce production changes solely for testing without the normal separate change process.
8. Measure collection latency, backlog recovery, API usage and storage growth; tune budgets and agree retention/backups.
9. Complete DBA user acceptance testing, enable scheduled monitoring, and provide operating/support handover.

## 13. Acceptance criteria

| Area | Required evidence |
|---|---|
| Capture | Existing CREATE/ALTER/DROP fixtures for supported object types are collected with original fields and SAST timestamps intact. |
| Reliability | Reruns do not duplicate events; late commits are recovered; cursor failures do not lose events; duplicate/conflicting IDs and source resets surface as errors. |
| Repository | Exact and safely normalized supported matches succeed; meaningful SQL differences remain visible; only master is used for the master verdict. |
| Release | Relevant SSDT_SA links are found across supported fields; mismatched server/database/window and incomplete evidence require review. |
| Approval | Names/comments/timestamps are displayed without allowlist, approval-text interpretation or approval-timing verdict. No linked record is labelled automatically approved. |
| Independence | A master match can coexist with a RAB exception, and a linked release can coexist with a repository exception. |
| Completeness | Pagination limits, API errors, hidden metadata and incomplete scans are visible and do not create false confidence. |
| Dashboard | SAST day boundaries, filters, evidence details, stale warnings and explicit demo separation work correctly. |
| Security | Scheduled identity can collect/export; unauthorized users cannot retrieve the site or JSON; secrets are absent from outputs and web content. |
| Read-only sources | Review and canary confirm no captured SQL execution and no production SQL/repository/Jira mutations by the collector. |
| Operations | Schedule, failure monitoring, credential rotation, backups, retention, restart and stop procedures are documented and tested as applicable. |
| Performance | DBA-approved query cost and agreed run/backlog behaviour are demonstrated with measured results. |

## 14. Decisions and ownership to close

The receiving team should resolve these with the DBA/infrastructure owners:

- Named application owner, DBA owner, infrastructure owner and ongoing support contact.
- Target delivery date, support hours and acceptable freshness/backlog thresholds.
- Actual source index/retention state and the result of the previously successful user check.
- API credential ownership, permitted token/authentication method and rotation arrangements.
- Verified database folder mappings, Jira custom-field IDs and any explicitly accepted server aliases.
- DBA access group, dashboard URL, IIS physical path, share and SQL Agent proxy.
- Central evidence retention, backup/recovery requirements and storage capacity.
- Whether the dashboard remains standalone or is linked from DBA Morning Checks.

No approver list is required to close this project.

## 15. Deliverables and handover contents

Please return the reviewed source/configuration, a tested installation package, live validation evidence, DBA UAT sign-off, environment/access inventory without secrets, and an operational runbook with named support ownership and outstanding limitations.

Supplied supporting documents:

- `README.md`: project overview and current boundary.
- `RUNBOOK.md`: installation, permissions, operation and known limits.
- `CREDENTIAL_SETUP.md`: credential setup and connection check steps.
- `DISCOVERY.md`: dated repository/Jira observations; historical approval wording is superseded as noted above.
- `VALIDATION.md`: recorded offline test results and live-validation gaps.
- `config/target.json`, `sql`, `powershell`, `wwwroot`, `tests`: implementation and configuration.

Stopping the monitor means disabling its SQL Agent job and setting `scheduledCollectionEnabled` to false. Retain central history. Since the monitor does not deploy source changes, stopping it requires no production schema rollback.
