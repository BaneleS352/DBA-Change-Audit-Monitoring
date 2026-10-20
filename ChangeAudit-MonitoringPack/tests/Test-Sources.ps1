$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\powershell\Audit.Sources.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\..\powershell\Audit.Core.psm1" -Force -DisableNameChecking
Initialize-SqlParser 'C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\Extensions\Application\Microsoft.SqlServer.TransactSql.ScriptDom.dll'
$script:checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
$blocked=$false;try{Invoke-ReadApi 'https://unrelated.example/anything' @{}}catch{$blocked=$true}
Assert $blocked 'Reject credentials sent to unconfigured service host'
$sources=Get-Module Audit.Sources
& $sources {
 $script:mode='normal';$script:downloads=0;$script:requests=@()
 function script:Invoke-ReadApi([string]$Uri,[hashtable]$Headers){
  $script:requests+=$Uri
  if($Uri -match '/filter/10528'){return [pscustomobject]@{jql='issuetype = Release ORDER BY created DESC'}}
  if($Uri -match '/field$'){return @([pscustomobject]@{name='RAB Approver';id='customfield_10001'})}
  if($Uri -match '/search/jql'){
   if($script:mode -eq 'stalled'){return [pscustomobject]@{issues=@();isLast=$false;nextPageToken='same'}}
   if($Uri -match 'nextPageToken=two'){return [pscustomobject]@{issues=@([pscustomobject]@{id='2';key='TEST-2';fields=@{}});isLast=$true}}
   return [pscustomobject]@{issues=@([pscustomobject]@{id='1';key='TEST-1';fields=@{}});isLast=$false;nextPageToken='two'}
  }
  if($Uri -match '/refs\?'){return [pscustomobject]@{value=@([pscustomobject]@{name='refs/heads/master';objectId=('a'*40)})}}
  if($Uri -match 'recursionLevel=Full'){
   return [pscustomobject]@{value=@([pscustomobject]@{path='/SyX';isFolder=$true},[pscustomobject]@{path='/SyX/dbo/one.sql';objectId=('b'*40);isFolder=$false},[pscustomobject]@{path='/SyX/dbo/two.sql';objectId=('c'*40);isFolder=$false})}
  }
  if($Uri -match 'includeContent=true'){$script:downloads++;return [pscustomobject]@{content='CREATE PROCEDURE dbo.p AS SELECT 1;'}}
  if($Uri -match '/comment\?'){
   if($Uri -match 'startAt=1'){return [pscustomobject]@{total=2;comments=@(@{id='c2'})}}
   return [pscustomobject]@{total=2;comments=@(@{id='c1'})}
  }
  if($Uri -match '/changelog\?'){return [pscustomobject]@{total=0;values=@()}}
  throw "Unexpected mock request: $Uri"
 }
}
$config=[pscustomobject]@{repositoryId='repo';databaseFolderMappings=@();rabSource=[pscustomobject]@{baseUrl='https://betsoftware.atlassian.net';filterId='10528';verifiedFilterJql='issuetype = Release ORDER BY created DESC';observedFieldLabels=[pscustomobject]@{rabApprover='RAB Approver'};fieldMappings=$null};limits=[pscustomobject]@{jiraPagesPerRun=3;jiraDetailPages=3;repositoryFilesPerRun=1}}
$jira=Get-JiraSnapshot $config @{}
Assert ($jira.Complete -and $jira.Issues.Count -eq 2) 'Jira continuation pages consumed'
Assert ($jira.FieldMap.rabApprover -eq 'customfield_10001') 'Resolve labels to actual API field IDs'
$config.limits.jiraPagesPerRun=1
Assert (-not (Get-JiraSnapshot $config @{}).Complete) 'Page cap explicitly reports incomplete scope'
$config.limits.jiraPagesPerRun=3
& $sources {$script:mode='stalled'}
$blocked=$false;try{Get-JiraSnapshot $config @{}}catch{$blocked=$true}
Assert $blocked 'Repeated continuation token fails instead of claiming complete'
& $sources {$script:mode='normal'}
$details=Get-JiraDetails 'TEST-1' $config @{}
Assert ($details.commentComplete -and $details.comment.Count -eq 2 -and $details.changelogComplete) 'Comments have independent complete pagination'
$config.limits.jiraDetailPages=1
Assert (-not (Get-JiraDetails 'TEST-1' $config @{}).commentComplete) 'Comment cap remains incomplete'
$cache=Join-Path $env:TEMP ('audit-cache-test-'+[guid]::NewGuid().ToString('N'))
try{
 $first=Get-RepositorySnapshot $config @{} @('SyX') $cache
 Assert (-not $first.Scopes.SyX.Complete -and $first.Artifacts.Count -eq 1) 'Master warmup is bounded and incomplete'
 $second=Get-RepositorySnapshot $config @{} @('SyX') $cache
 Assert ($second.Scopes.SyX.Complete -and $second.Artifacts.Count -eq 2) 'Next run reuses immutable cache and finishes scope'
 Assert ((& $sources {$script:downloads}) -eq 2) 'Unchanged blob is not downloaded twice'
 $unmapped=Get-RepositorySnapshot $config @{} @('SyXAudit') $cache
 Assert (-not $unmapped.Scopes.SyXAudit.Complete -and $unmapped.Artifacts.Count -eq 0) 'No prefix match between SyX and SyXAudit folders'
 $requests=& $sources {$script:requests}
 Assert (@($requests | Where-Object {$_ -match 'includeContent=true' -and $_ -notmatch ('versionDescriptor.version='+('a'*40))}).Count -eq 0) 'Every SQL download pinned to the same resolved master commit'
}finally{
 # Remove only files created by this test, without recursive deletion.
 if(Test-Path -LiteralPath $cache){Get-ChildItem -LiteralPath $cache -File | Remove-Item;Remove-Item -LiteralPath $cache}
}
Remove-Module Audit.Sources
Write-Output "PASS: $script:checks mocked adapter assertions. No live API or database calls."
