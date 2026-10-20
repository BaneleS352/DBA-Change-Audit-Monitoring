# What is needed for repository and Jira access?

The scheduled collector runs as `HOLLYWOODBETS\SentryOne`. It can use Windows authentication for SQL. Azure DevOps and Jira need separate API sign-in details, because they cannot use the Codex browser session.

You need these three values. **Enter them on the collector server, not in chat.**

| Value | Where it comes from | Used for |
|---|---|---|
| Azure DevOps personal access token (PAT) | Your Azure DevOps account with SSDT_SA access | Reading master files and PRs |
| Jira account email | The email you use to sign into Atlassian | Identifying the Jira account |
| Jira API token | That Atlassian account's API-token page | Reading releases and comments |

## A. Azure DevOps

1. Sign into the BETSoftwareO365 organization with your approved external-access account.
2. Open User settings → Personal access tokens → New Token.
3. Name it `DBA Change Audit Read`, restrict it to BETSoftwareO365, select an expiry per company policy, and select **Code: Read**.
4. Create it and keep the value available only for the server-side credential prompt below. If token creation is restricted, ask your Azure DevOps administrator to provision the approved authentication method; do not request write scopes.

[Microsoft PAT instructions](https://learn.microsoft.com/en-us/azure/devops/integrate/get-started/authentication/pats)

## B. Jira

1. Open [Atlassian API tokens](https://id.atlassian.com/manage-profile/security/api-tokens) using the account that can view filter 10528.
2. Create an API token with a descriptive label and expiry per company policy. The current pack supports a **token without scopes** against betsoftware.atlassian.net.
3. Record which Atlassian email owns the token. This is not the Windows account string `HOLLYWOODBETS\DouglasN` unless that is actually your Atlassian sign-in identifier.

The app only sends GET requests, but a token without scopes inherits the account's permissions; it is not itself restricted to read-only. If company policy requires scoped Jira tokens or OAuth, use that policy and tell me: the adapter must be configured for the scoped-token gateway before use. A scoped token cannot simply be substituted into the current tenant-URL setup.

[Atlassian token instructions and scoped-token URLs](https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/)

## C. Save on HSB-SENTRY-SQL

Have the collector scripts installed under `E:\DBA\ChangeAudit`, and create the private `secrets` directory with the access described in RUNBOOK.md. Run the following **as SentryOne on that host**, through your approved account-execution method:

```powershell
E:\DBA\ChangeAudit\powershell\Initialize-AuditCredentials.ps1 -Path E:\DBA\ChangeAudit\secrets\api-credentials.xml
```

There are two prompts:

1. **Azure:** leave the username label; paste the Azure PAT in the password field.
2. **Jira:** enter the Atlassian email as username; paste the Jira API token in the password field.

This saves encrypted credentials tied to SentryOne and this computer. Do not create the file under your own Windows identity and copy it across: SentryOne would not be able to decrypt it. If service-account execution is managed by infrastructure, give them this step to perform. No Windows password belongs in either API password field.

## D. Check the connections

Under the same identity on the same host:

```powershell
E:\DBA\ChangeAudit\powershell\Test-AuditConnections.ps1 -ReportPath E:\DBA\ChangeAudit\connection-report.json
```

The report contains status, field IDs and observed display names, not tokens. Check it for errors before running the collector. You can share the non-secret errors or relevant status sections to diagnose a failure.

No approver allowlist is required. Approver names are now informational for the DBA checking the dashboard.
