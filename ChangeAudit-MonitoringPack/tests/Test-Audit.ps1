[CmdletBinding()]
param([string]$ScriptDomPath='C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\Extensions\Application\Microsoft.SqlServer.TransactSql.ScriptDom.dll')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\powershell\Audit.Core.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\..\powershell\Audit.Sources.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\..\powershell\Audit.Reconcile.psm1" -Force -DisableNameChecking
Initialize-SqlParser $ScriptDomPath
$script:checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function Event([string]$Sql){return [pscustomobject]@{EventId=1;DatabaseName='SyX';SchemaName='dbo';ObjectName='p';EventType='ALTER_PROCEDURE';SqlCommand=$Sql;EventAtUtc=[datetime]'2026-09-15T10:00:00Z'}}
function Artifact([string]$Sql){return [pscustomobject]@{Path='/SyX/dbo/Stored Procedures/p.sql';Commit=('a'*40);ContentHash=Get-Hash $Sql;Parsed=Read-SqlEvidence $Sql 'SyX'}}
$event=Event "ALTER PROCEDURE dbo.p AS SELECT 'A B';"
$match=Compare-RepositoryEvidence $event @((Artifact "create procedure dbo.p AS /* comment */ select 'A B';")) $true
Assert ($match.Status -eq 'Matched') 'CREATE/ALTER module body comparison with safe comment/whitespace handling'
Assert ($match.Matches[0].Method -eq 'DefinitionMatch') 'Definition match labelled separately from operation'
Assert ((Compare-RepositoryEvidence $event @((Artifact "CREATE PROCEDURE [dbo].[p] AS SELECT 'A B';")) $true).Status -eq 'Matched') 'Quoted identifiers normalize without changing identifier case'
Assert ((Compare-RepositoryEvidence (Event "CREATE OR ALTER PROCEDURE dbo.p AS SELECT 'A B';") @((Artifact "CREATE PROCEDURE dbo.p AS SELECT 'A B';")) $true).Status -eq 'Matched') 'CREATE OR ALTER may emit an ALTER event for an existing module'
foreach($literal in @('AB','A  B','a b')){
 $result=Compare-RepositoryEvidence $event @((Artifact "CREATE PROCEDURE dbo.p AS SELECT '$literal';")) $true
 Assert ($result.Status -eq 'Different') "Preserve literal differences: $literal"
}
Assert ((Read-SqlEvidence 'CREATE PROCEDURE p AS SELECT 1;' 'SyX').Supported -eq $false) 'Reject implicit schema'
Assert ((Read-SqlEvidence "USE OtherDb;`nGO`nCREATE PROCEDURE dbo.p AS SELECT 1;" 'SyX').Supported -eq $false) 'Wrong database context rejected'
Assert ((Read-SqlEvidence 'DROP PROCEDURE dbo.p, dbo.q;' 'SyX').Supported -eq $false) 'Multi-object DROP unsupported'
$context=Compare-RepositoryEvidence $event @((Artifact "SET ANSI_NULLS ON;`nGO`nCREATE PROCEDURE dbo.p AS SELECT 'A B';")) $true
Assert ($context.Status -ne 'Matched') 'Differing session context cannot match'
$missing=Compare-RepositoryEvidence $event @() $false
Assert ($missing.Status -eq 'Unknown') 'Incomplete repository never reports missing'
Assert ((Compare-RepositoryEvidence $event @() $true).Status -eq 'NotFound') 'Complete empty index can report scoped absence'
$wrong=Event 'ALTER PROCEDURE dbo.q AS SELECT 1;'
Assert ((Compare-RepositoryEvidence $wrong @() $true).Status -eq 'NeedsReview') 'EVENTDATA identity must match parsed object'
$table=[pscustomobject]@{DatabaseName='SyX';SchemaName='dbo';ObjectName='t';EventType='ALTER_TABLE';SqlCommand='ALTER TABLE dbo.t ADD j int;'}
Assert ((Compare-RepositoryEvidence $table @((Artifact 'CREATE TABLE dbo.t (i int,j int);')) $true).Status -eq 'NeedsReview') 'Desired-state table is not proof of ALTER operation'
$day=Get-SastDayBounds ([datetime]'2026-09-15T22:05:00Z')
Assert ($day.Date -eq '2026-09-16') 'SAST day changes at 22:00 UTC'
Assert ($day.StartUtc.ToString('yyyy-MM-ddTHH:mm') -eq '2026-09-15T22:00') 'SAST midnight UTC boundary'
Assert ((ConvertFrom-JiraDate '2026-09-15T12:00:00.000+0200').ToString('HH:mm') -eq '10:00') 'Jira explicit offset conversion'
function Comment([string]$Text,[string]$Time,[string]$Author='account-1'){
 return @{id='1';created=$Time;updated=$Time;author=@{accountId=$Author};updateAuthor=@{accountId=$Author};body=@{type='doc';content=@(@{type='paragraph';content=@(@{type='text';text=$Text})})}}
}
$sampleIssue=@{fields=@{approver=@{accountId='unlisted-id';displayName='Example Approver'}}}
$display=Get-ApprovalDisplay $sampleIssue @{comment=@((Comment 'Not approved' '2026-09-15T11:00:00Z' 'any-account'));commentComplete=$true} @{rabApprover='approver';rabApprovers='others'}
Assert ($display.Mode -eq 'ManualReview') 'No automated approval decision'
Assert ($display.Approvers[0].Name -eq 'Example Approver') 'Recorded approver name displayed without allowlist'
Assert ($display.Comments[0].Text.Trim() -eq 'Not approved') 'Raw comment evidence retained without approving or rejecting it'
Assert ($display.Comments[0].Created -eq '2026-09-15T11:00:00Z') 'Comment timestamp retained for human verification'
Assert (-not (Get-ApprovalDisplay $sampleIssue $null @{rabApprover='approver';rabApprovers='others'}).CommentsComplete) 'Missing comments explicitly incomplete'
$eventTime=([DateTimeOffset]'2026-09-15T10:00:00Z').UtcDateTime
Assert (Test-ScopeText 'Server: HSB-SYX20-SQL01 DB: SyX' 'HSB-SYX20-SQL01' 'SyX') 'Exact server and database scope'
Assert (-not (Test-ScopeText 'Server: HSB-SXY20-SQL01 DB: SyX' 'HSB-SYX20-SQL01' 'SyX')) 'No fuzzy server typo correction'
Assert (-not (Test-ScopeText 'Server: HSB-SYX20-SQL01 DB: SyXAudit' 'HSB-SYX20-SQL01' 'SyX')) 'Database token boundaries'
Assert (-not (Test-ScopeText 'SA Server: HSB-SYX20-SQL01 DB: Betting LF Server: HSB-CPR-SQL01 DB: SyX' 'HSB-SYX20-SQL01' 'SyX')) 'Do not combine SA server with another platform database'
$issue=@{fields=@{description=@{type='doc';content=@(@{type='paragraph';content=@(@{type='text';text='SA';marks=@(@{type='link';attrs=@{href='https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_git/SSDT_SA/pullrequest/82924'}})})})};customfield_pr='https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_git/SSDT_Mozambique/pullrequest/83389'}}
$ids=@(Get-SaPullRequestIds $issue @{pullRequest='customfield_pr';deploymentInstructions='customfield_instructions'})
Assert ($ids.Count -eq 1 -and $ids[0] -eq 82924) 'Description SA link overrides unrelated dedicated-field repository'
Assert ((Get-OverallStatus 'Matched' 'Linked' $eventTime 15 $eventTime.AddHours(1)) -eq 'EvidenceLinked') 'Linked evidence does not claim approval'
Assert ((Get-OverallStatus 'NotFound' 'ApprovalAfterChange' $eventTime 15 $eventTime.AddHours(1)) -eq 'BothExceptions') 'Independent gaps combined'
Assert ((Get-OverallStatus 'Unknown' 'Unknown' $eventTime 15 $eventTime.AddMinutes(1)) -eq 'Pending') 'Grace period only delays exception label'
Assert ((Get-OverallStatus 'Matched' 'Unknown' $eventTime 15 $eventTime.AddHours(1)) -eq 'NeedsReview') 'Unknown evidence not covered'
$fieldMap=@{deploymentStart='start';deploymentEnd='end';deploymentInstructions='instructions';rabApprover='approver';rabApprovers='approvers'}
$issue=[pscustomobject]@{key='TEST-1';fields=@{created='2026-09-14T10:00:00Z';description='';instructions='SA Server: HSB-SYX20-SQL01 DB: SyX';start='2026-09-15T09:30:00Z';end='2026-09-15T10:30:00Z';approver=@{accountId='account-1'}}}
$details=@{comment=@((Comment 'Approved' '2026-09-15T09:00:00Z'));changelog=@();commentComplete=$true;changelogComplete=$true}
$pr=@{status='completed';targetRefName='refs/heads/master';closedDate='2026-09-15T08:00:00Z';pullRequestId=1}
$candidate=[pscustomobject]@{Issue=$issue;Pr=$pr;Details=$details;FieldMap=$fieldMap;ArtifactMatches=$true}
$candidateConfig=@{sourceServer='HSB-SYX20-SQL01';approvedServerAliases=@();approvalPolicy=@{mode='ManualReview'};rabSource=@{baseUrl='https://betsoftware.atlassian.net'}}
$e=Event 'ALTER PROCEDURE dbo.p AS SELECT 1;';$e.EventAtUtc=([DateTimeOffset]'2026-09-15T10:00:00Z').UtcDateTime
Assert ((Get-RabVerdict $e @($candidate) $true $candidateConfig).Status -eq 'Linked') 'Release linkage is independent of approval authorization'
$pr.status='active'
Assert ((Get-RabVerdict $e @($candidate) $true $candidateConfig).Status -eq 'Linked') 'RAB linkage does not certify PR or approver approval'
$pr.status='completed';$pr.closedDate='2026-09-15T09:15:00Z'
Assert ((Get-RabVerdict $e @($candidate) $true $candidateConfig).Status -eq 'Linked') 'Approval timing is left to manual verification'
$pr.closedDate='2026-09-15T08:00:00Z';$issue.fields.end=$null
Assert ((Get-RabVerdict $e @($candidate) $true $candidateConfig).Status -eq 'NeedsReview') 'Missing deployment bound not guessed'
$issue.fields.end='2026-09-15T10:30:00Z';$issue.fields.start='2026-09-15T10:15:00Z'
Assert ((Get-RabVerdict $e @($candidate) $true $candidateConfig).Status -eq 'OutsideWindow') 'Execution outside recorded window flagged'
Assert ((Get-RabVerdict $e @() $false $candidateConfig).Status -eq 'Unknown') 'Incomplete Jira evidence cannot establish absence'
Assert ((Get-RabVerdict $e @() $true $candidateConfig).Status -eq 'NotFoundInScope') 'Complete scan absence labelled by scope'
$testPath=Join-Path $env:TEMP ('audit-test-'+[guid]::NewGuid().ToString('N')+'.json')
try {
 Write-AtomicJson $testPath @{value='first'};Write-AtomicJson $testPath @{value='replacement'}
 Assert (((Get-Content -LiteralPath $testPath -Raw | ConvertFrom-Json).value) -eq 'replacement') 'Atomic replace exports complete JSON'
} finally {if(Test-Path -LiteralPath $testPath){Remove-Item -LiteralPath $testPath}}
foreach($file in Get-ChildItem "$PSScriptRoot\..\powershell" -File){$tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors);Assert ($parseErrors.Count -eq 0) "PowerShell parses: $($file.Name)"}
$parser=New-Object Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser $true
foreach($file in Get-ChildItem "$PSScriptRoot\..\sql" -Filter *.sql){$parseErrors=$null;$null=$parser.Parse([IO.StringReader]::new((Get-Content $file.FullName -Raw)),[ref]$parseErrors);Assert ($parseErrors.Count -eq 0) "SQL parses: $($file.Name)"}
Write-Output "PASS: $script:checks offline assertions. No SQL Server or external API connections were made."
