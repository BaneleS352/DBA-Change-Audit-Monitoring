[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Credential initialization requires Windows DPAPI.' }
if (Test-Path -LiteralPath $Path) { throw 'Credential file exists. Use a new filename for rotation, then update configuration.' }
Write-Host 'Run on the collector host AS HOLLYWOODBETS\SentryOne. Enter existing API credentials issued for the external-access account.'
Write-Host 'Azure: username is a label; password is an Azure DevOps PAT with Code Read. Jira: username is Atlassian email; password is its API token.'
$azure = Get-Credential -Message 'Azure DevOps read-only PAT' -UserName 'HOLLYWOODBETS\DouglasN'
$jira = Get-Credential -Message 'Jira email and API token (not Windows credentials)'
if ($null -eq $azure -or $null -eq $jira) { throw 'Credential entry cancelled' }
@{ AzurePat = $azure; Jira = $jira } | Export-Clixml -LiteralPath $Path
Write-Host 'Saved DPAPI-encrypted credentials for this Windows identity and host. Keep the file outside the IIS site and restrict its directory ACL.'
