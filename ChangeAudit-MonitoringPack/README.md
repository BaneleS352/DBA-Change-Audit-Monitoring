# DBA Change Audit

Read-only monitoring of changes recorded in `DBA.dbo.__schema_change_tracking` on `HSB-SYX20-SQL01`, compared with SQL definitions in the Affiliates.Database repository's `main` branch.

**Current phase:** SQL event to Azure DevOps comparison for the `Affiliates` database. RAB/Jira lookup is deferred. The collector never executes captured SQL or writes to Azure DevOps.

## Configuration

| Component | Configuration |
|---|---|
| Source | `HSB-SYX20-SQL01` / `DBA.dbo.__schema_change_tracking` |
| Database in scope | `Affiliates` |
| Repository | [Affiliates.Database · main](https://dev.azure.com/BETSoftwareO365/Affiliates/_git/Affiliates.Database?version=GBmain) |
| Central SQL | `HSB-SENTRY-SQL` / `DBA_ChangeAudit` |
| Dashboard | IIS on `HSB-SENTRY-APP1` |
| SQL collector identity | `HOLLYWOODBETS\SentryOne` |
| API access | Azure DevOps PAT with Code Read; entered securely on the collector host |

The dashboard shows the source event fields, captured SQL, repository result, exact commit, and collection health. The current repository mapping treats the repository root as the Affiliates SQL scope; confirm this against the actual repository tree before relying on missing-file results.

## Files

- [RUNBOOK.md](RUNBOOK.md): installation, permissions, collection, and operational limits.
- [CREDENTIAL_SETUP.md](CREDENTIAL_SETUP.md): secure PAT setup and connection check.
- [config/target.json](config/target.json): SQL source, repository, branch, paths, and read budgets.
- [sql/001_CreateChangeAudit.sql](sql/001_CreateChangeAudit.sql): central history and dashboard procedures.
- [powershell/Collect-ChangeAudit.ps1](powershell/Collect-ChangeAudit.ps1): collector and assessment runner.
- [wwwroot/index.html](wwwroot/index.html): dashboard; `?demo=1` explicitly loads synthetic examples.

## Before live use

1. Rotate any PAT shared in chat, then save the replacement as SentryOne on the collector host using the secure credential prompt.
2. Confirm the `Affiliates` database name and repository root mapping against actual source rows and repository contents.
3. Inspect source indexes, retention, trigger coverage, SQL permissions, central stored procedure permissions, and IIS/JSON ACLs.
4. Run the connection report and a manual canary. Scheduling remains disabled by default.

Current SQL comparison is conservative: unsupported SQL, incomplete repository reads, and ambiguous mappings remain unknown or need review. A current repository match does not prove a change was approved or historically deployed. See [RUNBOOK.md](RUNBOOK.md) for limits and setup details.
