# Azure DevOps credential setup

The collector runs as `HOLLYWOODBETS\SentryOne`. It uses Windows authentication for SQL and an Azure DevOps PAT with **Code: Read** for the Affiliates.Database repository. The PAT is not stored in the app configuration or source files.

## Save the PAT on the collector host

Install the collector under `E:\DBA\ChangeAudit`, create a private `secrets` directory, and run the following **on the collector host as SentryOne** through your approved account-execution method:

```powershell
E:\DBA\ChangeAudit\powershell\Initialize-AuditCredentials.ps1 -Path E:\DBA\ChangeAudit\secrets\api-credentials.xml
```

Enter the PAT in the secure password prompt. The username is only a label. The script saves a DPAPI-encrypted credential tied to that Windows identity and computer; creating it under another account will prevent SentryOne from decrypting it. Keep the file outside IIS with a restricted ACL.

For rotation, create a replacement file with a new name, update `credentialPath`, verify connectivity, then retire the prior credential under your credential process. Do not put PAT values in configuration, logs, reports, or chat.

## Check access

Under the same identity on the same host:

```powershell
E:\DBA\ChangeAudit\powershell\Test-AuditConnections.ps1 -ReportPath E:\DBA\ChangeAudit\connection-report.json
```

The report includes SQL permissions, the repository identity, and the configured branch/ref status. It does not include the PAT. Review any errors before running the collector.

Azure DevOps access must be over HTTPS to `dev.azure.com`. The application only sends read requests. Token expiry and rotation remain the credential owner's responsibility.
