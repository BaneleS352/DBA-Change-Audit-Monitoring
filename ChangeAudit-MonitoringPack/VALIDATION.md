# Validation status

The 2026-09-16 validation record applies to the earlier SSDT_SA/Jira implementation and does not validate the Affiliates.Database/main changes made in this phase.

The current changes have not been tested. Before enabling collection, validate:

- Azure DevOps Code Read access, repository identity, and `refs/heads/main` using the connection report.
- The root-folder mapping against the repository's actual deployable SQL layout; update `databaseFolderMappings` if definitions live below root.
- SQL procedure deployment, including the optional database filter parameters, and SentryOne EXECUTE permissions.
- Source read permissions, indexes, trigger coverage, retention, central SQL, and IIS/JSON ACLs.
- An end-to-end canary using existing authorized events, confirming captured SQL, object identity, comparison result, pinned commit, and SAST time display.

The monitor does not create SQL events or write repository changes as part of validation. Keep the SQL Agent schedule disabled until live checks and DBA review are complete.
