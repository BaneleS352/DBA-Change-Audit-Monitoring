# DBA Change Audit

Read-only monitoring of schema changes on HSB-SYX20-SQL01, compared with SSDT_SA master and Jira release evidence for DBA review.

**Status:** implementation and setup pack built and tested offline. No live installation or end-to-end SQL/API validation has been performed. Start with [RUNBOOK.md](RUNBOOK.md). Browser discovery is recorded in [DISCOVERY.md](DISCOVERY.md).

## Confirmed setup

| Component | Configuration |
|---|---|
| Source | HSB-SYX20-SQL01 / DBA.dbo.__schema_change_tracking |
| Central SQL | HSB-SENTRY-SQL / DBA_ChangeAudit |
| IIS | HSB-SENTRY-APP1 |
| SQL execution identity | HOLLYWOODBETS\SentryOne |
| External read identity | HOLLYWOODBETS\DouglasN; separate API credentials required |
| Repository | [SSDT_SA master](https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_git/SSDT_SA?version=GBmaster) |
| Release source | [Jira AllReleases / 10528](https://betsoftware.atlassian.net/issues/?filter=10528) |
| Display | Today's SAST activity; older evidence is retained centrally |
| Approval | Display recorded approver names/comments/times; DBA verifies validity |

The monitor never executes captured SQL, deploys changes, modifies triggers/indexes, writes Git content, or posts/approves Jira records. Its writes are central monitoring history, local caches/credential configuration, and exported dashboard JSON.

## Included

- Central SQL schema, append-only event/assessment procedures and source cursors.
- PowerShell collectors with read-only GET adapters, bounded source reads, rotating retained-ID reconciliation, immutable content caching and pinned master revisions.
- Microsoft ScriptDom parsing and conservative SQL statement/definition comparison.
- Jira custom-field discovery, pagination, PR linking and recorded approver names and comment timestamps for human review.
- Trigger coverage, errors, backlog and evidence completeness in collection health.
- Static IIS dashboard with SAST date filtering, independent verdicts, filters and captured-SQL evidence.
- A disabled five-minute SQL Agent job template, credential setup, connection checks and offline tests.

## Files

- [RUNBOOK.md](RUNBOOK.md): setup, access, operational limits and canary checks.
- [config/target.json](config/target.json): target settings, budgets and manual review settings.
- [sql/001_CreateChangeAudit.sql](sql/001_CreateChangeAudit.sql): central storage only.
- [powershell/Collect-ChangeAudit.ps1](powershell/Collect-ChangeAudit.ps1): monitoring runner.
- [powershell/Test-AuditConnections.ps1](powershell/Test-AuditConnections.ps1): read-only host connection/field report.
- [wwwroot/index.html](wwwroot/index.html): production dashboard; explicit ?demo=1 loads synthetic examples.
- [tests/Test-Audit.ps1](tests/Test-Audit.ps1) and [tests/Test-Sources.ps1](tests/Test-Sources.ps1): offline validation.

## Remaining configuration before live use

1. Create encrypted Azure DevOps/Jira read credentials as SentryOne on the collector host. A Windows account name or browser login is not unattended cloud authentication.
2. No approver list is required. The dashboard displays recorded Jira approvers and comment authors; the DBA verifies approval validity and timing.
3. Run source index/permission inspection and the connection report. SQL01's supplied table has no declared index; the monitor pauses an unindexed LogId scan unless the DBA explicitly accepts its measured read cost. It never creates the index itself.
4. Install central storage and IIS with DBA-only access to the entire site, including JSON. Run a manual canary, then enable the monitoring schedule.

## Matching limits

A match in current master does not prove an earlier deployment artifact. Release linkage checks matching PR content and target scope/window. The tool displays recorded approvers, comments and timestamps without deciding whether a person is authorized, a comment is approval, or approval is timely. “Evidence linked” is not “Approved”. Missing dates, ambiguous server names, unsupported SQL and incomplete scans remain review items.

“No RAB matched” means no matching evidence in the accessible configured release/PR/text scope, not proof that no RAB exists anywhere. SQL attachments/screenshots and other repositories are not automatically parsed. See the runbook for all limits.

The one-day setting filters the dashboard; it does not delete source logs or central history. Source retention must exceed outages and reconciliation backlog. Existing varchar data cannot recover Unicode already lost at capture.

## Validation

Core and mocked-adapter tests pass under Windows PowerShell 5.1 and PowerShell 7. SQL scripts parse with ScriptDom. Dashboard summary, search and evidence dialog were checked with synthetic browser data. Production SQL/API permissions, procedure execution, source performance and IIS ACLs remain unverified.
