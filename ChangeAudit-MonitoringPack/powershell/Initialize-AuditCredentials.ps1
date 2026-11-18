[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Credential initialization requires Windows DPAPI.' }
if (Test-Path -LiteralPath $Path) { throw 'Credential file exists. Use a new filename for rotation, then update configuration.' }
Write-Host 'Run on the collector host AS HOLLYWOODBETS\SentryOne. Enter the Azure DevOps PAT with Code Read permission.'
$azure = Get-Credential -Message 'Azure DevOps read-only PAT' -UserName 'PAT'
if ($null -eq $azure) { throw 'Credential entry cancelled' }
@{ AzurePat = $azure } | Export-Clixml -LiteralPath $Path
Write-Host 'Saved DPAPI-encrypted credentials for this Windows identity and host. Keep the file outside the IIS site and restrict its directory ACL.'
