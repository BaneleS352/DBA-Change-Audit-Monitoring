[CmdletBinding()]
param([string]$ConfigPath="$PSScriptRoot\..\config\target.json",[string]$ReportPath="$PSScriptRoot\..\connection-report.json")
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\Audit.Sql.psm1" -DisableNameChecking
Import-Module "$PSScriptRoot\Audit.Sources.psm1" -DisableNameChecking
Import-Module "$PSScriptRoot\Audit.Core.psm1" -DisableNameChecking
$config=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$report=[ordered]@{CheckedAtUtc=[DateTime]::UtcNow.ToString('o');ExecutionIdentity=[Security.Principal.WindowsIdentity]::GetCurrent().Name}
foreach($target in @(@{Name='Source';Server=$config.sourceServer;Database='DBA'},@{Name='Central';Server=$config.centralServer;Database=$config.centralDatabase})){
 $connection=New-AuditConnection $target.Server $target.Database
 try{
  $connection.Open()
  if($target.Name -eq 'Source'){
   $report.Source=@(Invoke-AuditSql $connection @'
SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS ServerName, SYSDATETIMEOFFSET() AS ServerTime,
 HAS_PERMS_BY_NAME(N'dbo.__schema_change_tracking',N'OBJECT',N'SELECT') AS CanReadTracking,
 OBJECT_ID(N'dbo.__schema_change_tracking') AS ObjectId;
SELECT TOP(0) LogId,DatabaseName,EventType,SchemaName,ObjectName,ObjectType,SqlCommand,EventDate,LoginName FROM dbo.__schema_change_tracking;
'@)
  }else{$report.Central=@(Invoke-AuditSql $connection "SELECT DB_NAME() AS DatabaseName, HAS_PERMS_BY_NAME(N'dbo.usp_BeginRun',N'OBJECT',N'EXECUTE') AS CanBeginRun;")}
 }catch{$report[$target.Name]=@{Error=$_.Exception.Message}}finally{$connection.Dispose()}
}
try{
 Initialize-SqlParser $config.scriptDomPath;$report.ScriptDom='OK'
 $headers=New-ReadHeaders $config.credentialPath
 $base='https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_apis/git/repositories/'+$config.repositoryId
 $refs=Invoke-ReadApi "$base/refs?filter=heads/master&api-version=7.1" $headers.Azure
 $report.Master=@($refs.value | Where-Object name -CEQ 'refs/heads/master' | Select-Object name,objectId)
 $mapping=Resolve-JiraFieldMap $config $headers.Jira;$report.JiraFieldMappings=$mapping
 $filter=Invoke-ReadApi ($config.rabSource.baseUrl+'/rest/api/3/filter/'+$config.rabSource.filterId) $headers.Jira
 $report.JiraFilter=@{Id=$filter.id;Name=$filter.name;Jql=$filter.jql}
 # Read configured representative releases to expose Jira account IDs for deliberate policy configuration.
 $people=@()
 foreach($key in $config.rabSource.sampleIssueKeys){
  $issue=Invoke-ReadApi ($config.rabSource.baseUrl+'/rest/api/3/issue/'+$key+'?fields='+[uri]::EscapeDataString(($mapping.rabApprover+','+$mapping.rabApprovers))) $headers.Jira
  foreach($field in @($mapping.rabApprover,$mapping.rabApprovers)){
   foreach($person in @(Get-Value $issue.fields $field @())){if($null -ne $person){$people += [pscustomobject]@{Issue=$key;Name=$person.displayName;AccountId=$person.accountId}}}
  }
 }
 $report.ObservedApprovers=$people
}catch{$report.External=@{Error=$_.Exception.Message}}
Write-AtomicJson $ReportPath $report
Write-Output "Read-only connection report saved to $ReportPath. It contains field/account IDs, not credentials. Review before scheduling."
