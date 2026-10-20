$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\powershell\Audit.Sql.psm1" -Force -DisableNameChecking
$module=Get-Module Audit.Sql
$script:checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
& $module {
 $script:state=$null;$script:stored=@{};$script:fingerprint='123|2026-09-01';$script:failStore=$false
 $script:rows=@()
 foreach($id in @(1,3)){$script:rows += [pscustomobject]@{LogId=$id;DatabaseName='SyX';SchemaName='dbo';ObjectName='p';ObjectType='PROCEDURE';EventType='ALTER_PROCEDURE';SqlCommand="ALTER PROCEDURE dbo.p AS SELECT $id;";LoginName='DOMAIN\test';EventDate=[datetime]'2026-09-15T12:00:00'}}
 function script:New-AuditConnection($Server,$Database){$fake=New-Object psobject;$fake|Add-Member ScriptMethod Open {};$fake|Add-Member ScriptMethod Dispose {};return $fake}
 function script:Invoke-AuditSql($Connection,[string]$CommandText,[hashtable]$Parameters=@{},[switch]$Procedure,[int]$Timeout=20){
  if($CommandText -match 'AS Fingerprint'){return [pscustomobject]@{Fingerprint=$script:fingerprint;HasLogIdIndex=1}}
  if($CommandText -eq 'dbo.usp_ReadState'){if($script:state){return $script:state};return}
  if($CommandText -match 'MAX\(LogId\)'){return [pscustomobject]@{MaxId=($script:rows|Measure-Object LogId -Maximum).Maximum}}
  if($CommandText -match 'TOP\(@BatchSize\)'){
   return @($script:rows | Where-Object {$_.LogId -gt $Parameters.AfterId -and $_.LogId -le $Parameters.UpperId} | Sort-Object LogId | Select-Object -First $Parameters.BatchSize)
  }
  if($CommandText -eq 'dbo.usp_StoreSourceBatch'){
   if($script:failStore){throw 'Simulated central commit failure'}
   $batch=$Parameters.EventsJson|ConvertFrom-Json
   foreach($row in $batch){$script:stored[[int]$row.LogId]=$row}
   $script:state=[pscustomobject]@{Fingerprint=$Parameters.Fingerprint;NewCursor=$Parameters.NewCursor;ReconcileCursor=$Parameters.ReconcileCursor}
   return
  }
  throw "Unexpected mock SQL: $CommandText"
 }
}
$config=[pscustomobject]@{sourceServer='TEST';sourceGeneration='c438cf91-cc30-42a5-a209-01957c2be661';allowUnindexedSourceRead=$false;checkTriggerCoverage=$false;limits=[pscustomobject]@{sourceRowsPerLane=500}}
$first=Read-AuditSource $config $null
Assert ($first.NewCursor -eq 3 -and $first.ReconcileCursor -eq 0) 'First collection reaches newest committed ID'
Assert ((& $module {$script:stored.Count}) -eq 2) 'Separate source events stored'
$utc=& $module {$script:stored[1].EventAtUtc}
Assert ($utc -eq '2026-09-15T10:00:00.000') 'Source local GETDATE converted from SAST'
& $module {$row=$script:rows[0].PSObject.Copy();$row.LogId=2;$row.SqlCommand='ALTER PROCEDURE dbo.p AS SELECT 2;';$script:rows+=$row}
$second=Read-AuditSource $config $null
Assert ((& $module {$script:stored.ContainsKey(2)}) -and $second.NewCursor -eq 3) 'Rotating reconciliation recovers late commit below high cursor'
$null=Read-AuditSource $config $null
Assert ((& $module {$script:stored.Count}) -eq 3) 'Replay does not duplicate source identities'
& $module {$row=$script:rows[0].PSObject.Copy();$row.LogId=4;$script:rows+=$row;$script:failStore=$true}
$failed=$false;try{Read-AuditSource $config $null}catch{$failed=$true}
Assert $failed 'Central commit failure propagates'
Assert ((& $module {$script:state.NewCursor}) -eq 3) 'Cursor does not advance after failed central commit'
& $module {$script:failStore=$false;$script:fingerprint='changed'}
$failed=$false;try{Read-AuditSource $config $null}catch{$failed=$true}
Assert $failed 'Changed source incarnation rejected'
& $module {$script:fingerprint=$script:state.Fingerprint;$script:rows=@($script:rows|Where-Object LogId -LT 3)}
$failed=$false;try{Read-AuditSource $config $null}catch{$failed=$true}
Assert $failed 'Decreased source maximum rejected'
Remove-Module Audit.Sql
Write-Output "PASS: $script:checks mocked collection assertions. No live SQL connections."
