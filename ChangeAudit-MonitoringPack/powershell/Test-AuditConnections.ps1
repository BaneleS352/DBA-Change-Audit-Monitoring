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
 $base=Get-RepositoryApiBase $config
 $repository=Invoke-ReadApi "$base?api-version=7.1" $headers.Azure
 $refs=Invoke-ReadApi "$base/refs?filter=heads/$($config.approvedBranch)&api-version=7.1" $headers.Azure
 $branch='refs/heads/'+$config.approvedBranch
 $branchRows=@($refs.value | Where-Object name -CEQ $branch | Select-Object name,objectId)
 if($branchRows.Count -ne 1){throw "Exactly one $branch ref was not returned"}
 $report.Repository=@{Id=$repository.id;Name=$repository.name;Branch=$branchRows}
}catch{$report.External=@{Error=$_.Exception.Message}}
Write-AtomicJson $ReportPath $report
Write-Output "Read-only connection report saved to $ReportPath. It contains connection status, not credentials. Review before scheduling."
