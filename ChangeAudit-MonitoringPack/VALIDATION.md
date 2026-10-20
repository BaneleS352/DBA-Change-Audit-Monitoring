# Validation record — 2026-09-16 update

Approval validity has moved to manual DBA review. The allowlist, authorization test, approval-text classification and automatic before/after approval verdict are removed.

Current validation:
- Test-Audit.ps1: 51 passing assertions.
- Test-Sources.ps1: 12 mocked API assertions.
- Test-Collection.ps1: 9 mocked source-collection assertions.
- JavaScript syntax, configuration JSON and SQL/PowerShell parse checks pass.
- Tests verify that an unlisted recorded approver is displayed, raw negative/late comments are preserved, timestamps are shown without validity decisions, and linked evidence never becomes an automatic approval.

The earlier 2026-09-15 approval-policy assertions are superseded. Existing offline source/API limitations in RUNBOOK.md still apply. No live credentials or SQL connections were used in these tests.

The user reported a successful host check on 2026-09-16; the exact script/result has not yet been identified, so this is not counted as full live-canary verification.
