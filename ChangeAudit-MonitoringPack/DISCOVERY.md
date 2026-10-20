# Authenticated discovery — 2026-09-15

Read-only browser inspection of SSDT_SA master, Jira AllReleases and two relevant database releases. These are observations, not results of comparing production change events. No SQL Server query, full Git snapshot, or complete Jira import was performed.

## Repository

Verified [master root](https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_git/SSDT_SA?version=GBmaster). Repository ID exposed by its build link: `dbb47529-e909-4417-8307-947e4db20598`.

Configuration records 26 root folders. `/Betting` contains `dbo`, `resulting`, `scripts`, `Security`, and `Betting.sqlproj`. Therefore schema must be part of object identity; not all objects live under dbo. Index SQL project items and SQL definitions recursively, distinguishing deployable definitions from supporting scripts. Do not assume every root folder is a live database; `CockroachDb`, for example, still requires classification.

The inspected PR displays paths such as `/Betting/resulting/Stored Procedures/GetInProgressAutoScratchingControl.sql`. A path is candidate evidence; parse its SQL to validate object identity before matching. The observed PR paths are not proof that the same definitions exist on master.

## Jira filter

[AllReleases, filter 10528](https://betsoftware.atlassian.net/issues/?filter=10528) has JQL:

```text
issuetype = Release ORDER BY created DESC
```

The UI shows 50 results and a 1000+ count, with mixed projects, environments and statuses including Done. There is no explicit date/status/project restriction in the saved query. API pagination and account visibility must still be verified before an absence is called Missing.

## Sample A: S20C-9455

[release Betting AutoScratchingControl Table and SPs](https://betsoftware.atlassian.net/browse/S20C-9455)

- Release type; current status To Do.
- Deployment start displayed as September 15, 2026, 14:30; end absent. Browser display timezone has not been independently verified.
- RAB Approver populated and an Approved comment visible. Assignment is not approval evidence, and the comment must be evaluated under the team's approval policy before automatic acceptance.
- Description links to SA PR 83261 and separate LuckyFish/Mozambique PRs. Dedicated Link to Pull Request is empty.
- Description specifies database `betting` and HWB-SA server `hsb-syx-sql01`, which does not exactly match monitored `HSB-SYX20-SQL01`. Keep as a scope discrepancy; do not infer an alias.
- Structured Environments field says Live; the separate Environment text still contains template guidance. Prefer validated structured fields and retain contradictory/missing evidence for review.

[SA PR 83261](https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_git/SSDT_SA/pullrequest/83261) was Active and targeted master at inspection. Some reviewer approvals were present; these do not establish merge completion or membership in master. A release-to-PR link can therefore establish a candidate without satisfying the master comparison.

## Sample B: SC-15636

[Update AutoResultSport_UOF Proc to Handle Resulting at Bet Type Level](https://betsoftware.atlassian.net/browse/SC-15636)

- Status Done, Release Outcome Successful, Environments Live.
- Deployment start absent; end displayed as September 15, 2026, 10:30. Do not invent a start or use issue creation time as deployment time.
- Description identifies SyX and contains SA PR 82924, LF PR 83337 and Mozambique PR 83389.
- Dedicated Link to Pull Request contains the Mozambique PR only. Reading that field alone would miss the SA evidence.
- Deployment Instructions contain `HSB-SXY20-SQL01` for SA, differing from monitored `HSB-SYX20-SQL01`. Treat as a possible typo needing review, not an approved server mapping.
- RAB Approver populated, with an Approved comment visible. Status Done does not by itself prove prior approval.

## Resulting matching contract

1. Discover Release issues across the configured filter with complete pagination; retain current fields and relevant histories/comments.
2. Extract PR links from the dedicated field, description and deployment instructions. Preserve where each link was found. For this server, select SSDT_SA by repository identity, not link order or an SA label alone.
3. Read linked PR status, target branch, changed files and immutable revisions. Keep PR review approval distinct from RAB approval.
4. Match source database/schema/object to candidate changed definitions and compare against a pinned master snapshot. Keep master content match separate from membership in the release's deployment artifact.
5. Assess target scope, logged time, approval evidence and deployment window independently. Missing start/end, ambiguous server names or approval semantics result in Needs review, not automatic coverage.
6. Preserve source spelling and all discrepancies. Approved server aliases are empty by default. Record any later reviewer correction separately from captured evidence.

## Follow-up implementation

- Implemented field-label resolution in the read-only API adapter and connection check; verify actual IDs on the execution host.
- Implemented encrypted API credential setup; existing browser login supports discovery only, not unattended service authentication.
- User confirmed source timezone as South African time. Live index/permission/retention checks remain necessary.
- Implemented central persistence, snapshots, adapters, reconciliation and read-only dashboard; see RUNBOOK.md for host setup and offline-versus-live validation boundaries.
