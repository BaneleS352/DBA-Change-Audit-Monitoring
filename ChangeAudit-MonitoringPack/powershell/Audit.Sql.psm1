Import-Module "$PSScriptRoot\Audit.Core.psm1" -DisableNameChecking
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-AuditConnection([string]$Server, [string]$Database) {
    $builder = New-Object Data.SqlClient.SqlConnectionStringBuilder
    $builder.DataSource=$Server; $builder.InitialCatalog=$Database; $builder.IntegratedSecurity=$true
    $builder.Encrypt=$true; $builder.TrustServerCertificate=$false; $builder.ConnectTimeout=10
    $builder.ApplicationName='DBA Change Audit Monitor'
    return New-Object Data.SqlClient.SqlConnection $builder.ConnectionString
}

function Invoke-AuditSql($Connection, [string]$CommandText, [hashtable]$Parameters=@{}, [switch]$Procedure, [int]$Timeout=20) {
    $cmd=$Connection.CreateCommand(); $cmd.CommandText=$CommandText; $cmd.CommandTimeout=$Timeout
    if ($Procedure) { $cmd.CommandType=[Data.CommandType]::StoredProcedure }
    foreach ($key in $Parameters.Keys) {
        $value=$Parameters[$key]
        $type=[Data.SqlDbType]::NVarChar
        if ($value -is [int]) { $type=[Data.SqlDbType]::Int }
        elseif ($value -is [long]) { $type=[Data.SqlDbType]::BigInt }
        elseif ($value -is [datetime]) { $type=[Data.SqlDbType]::DateTime2 }
        elseif ($value -is [guid]) { $type=[Data.SqlDbType]::UniqueIdentifier }
        $parameter=$cmd.Parameters.Add('@'+$key,$type)
        if ($type -eq [Data.SqlDbType]::NVarChar) { $parameter.Size=-1 }
        $parameter.Value=if ($null -eq $value) { [DBNull]::Value } else { $value }
    }
    $reader=$null
    try {
        $reader=$cmd.ExecuteReader(); $rows=New-Object 'System.Collections.Generic.List[object]'
        while ($reader.Read()) {
            $row=[ordered]@{}
            for ($i=0; $i -lt $reader.FieldCount; $i++) { $row[$reader.GetName($i)]=if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) } }
            $rows.Add([pscustomobject]$row)
        }
        $rows.ToArray()
    } finally { if ($reader) { $reader.Dispose() }; $cmd.Dispose() }
}

function Read-AuditSource($Config, $Central) {
    $source=New-AuditConnection $Config.sourceServer 'DBA'
    try {
        $source.Open()
        $meta=@(Invoke-AuditSql $source @'
SELECT CONVERT(nvarchar(20),t.object_id)+N'|'+CONVERT(nvarchar(33),t.create_date,126) AS Fingerprint,
 CASE WHEN EXISTS(SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id
 JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
 WHERE i.object_id=t.object_id AND i.is_disabled=0 AND i.has_filter=0 AND ic.key_ordinal=1 AND c.name=N'LogId') THEN 1 ELSE 0 END AS HasLogIdIndex
FROM sys.tables t WHERE t.object_id=OBJECT_ID(N'dbo.__schema_change_tracking');
'@)
        if ($meta.Count -ne 1) { throw 'Tracking table or metadata visibility missing' }
        if (-not $meta[0].HasLogIdIndex -and -not $Config.allowUnindexedSourceRead) { throw 'No leading LogId index found. Collector paused to avoid repeated heap scans; DBA must assess source read cost.' }
        $state=@(Invoke-AuditSql $Central 'dbo.usp_ReadState' @{ServerName=$Config.sourceServer;SourceGeneration=[guid]$Config.sourceGeneration} -Procedure)
        $newCursor=0; $reconcileCursor=0
        if ($state.Count) {
            if ($state[0].Fingerprint -cne $meta[0].Fingerprint) { throw 'Source table incarnation changed; review generation before resuming' }
            $newCursor=[int]$state[0].NewCursor; $reconcileCursor=[int]$state[0].ReconcileCursor
        }
        $top=@(Invoke-AuditSql $source 'SET LOCK_TIMEOUT 5000; SELECT ISNULL(MAX(LogId),0) AS MaxId FROM dbo.__schema_change_tracking;')
        $upper=[int]$top[0].MaxId
        if ($upper -lt $newCursor) { throw 'Source maximum ID decreased; possible purge/reset/restore. Review before resuming.' }
        $rows=New-Object 'System.Collections.Generic.Dictionary[int,object]'
        $query=@'
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET LOCK_TIMEOUT 5000;
SELECT TOP(@BatchSize) WITH TIES LogId, DatabaseName, SchemaName, ObjectName, ObjectType, EventType, SqlCommand, LoginName, EventDate
FROM dbo.__schema_change_tracking WHERE LogId>@AfterId AND LogId<=@UpperId ORDER BY LogId;
'@
        foreach ($lane in @('new','reconcile')) {
            $cursor=if ($lane -eq 'new') { $newCursor } else { $reconcileCursor }
            $batch=@(Invoke-AuditSql $source $query @{BatchSize=[int]$Config.limits.sourceRowsPerLane;AfterId=$cursor;UpperId=$upper})
            $laneSeen=New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($record in $batch) {
                if (-not $laneSeen.Add([int]$record.LogId)) { throw 'Duplicate LogId detected; source uniqueness required' }
                $local=[datetime]::SpecifyKind($record.EventDate,[DateTimeKind]::Unspecified)
                $event=[ordered]@{LogId=$record.LogId;DatabaseName=$record.DatabaseName;SchemaName=$record.SchemaName;ObjectName=$record.ObjectName;ObjectType=$record.ObjectType;EventType=$record.EventType;SqlCommand=$record.SqlCommand;LoginName=$record.LoginName;EventDateLocal=$local.ToString('yyyy-MM-ddTHH:mm:ss.fff');EventAtUtc=$local.AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ss.fff')}
                $event.SourceHash=Get-Hash (ConvertTo-JsonText $event)
                if ($rows.ContainsKey([int]$record.LogId) -and $rows[[int]$record.LogId].SourceHash -cne $event.SourceHash) { throw 'Source row changed during collection' }
                $rows[[int]$record.LogId]=[pscustomobject]$event
                $cursor=[int]$record.LogId
            }
            if ($lane -eq 'new') { $newCursor=$cursor } else { $reconcileCursor=if ($batch.Count -lt $Config.limits.sourceRowsPerLane -or $cursor -ge $upper) { 0 } else { $cursor } }
        }
        $null=Invoke-AuditSql $Central 'dbo.usp_StoreSourceBatch' @{ServerName=$Config.sourceServer;SourceGeneration=[guid]$Config.sourceGeneration;Fingerprint=$meta[0].Fingerprint;NewCursor=$newCursor;ReconcileCursor=$reconcileCursor;EventsJson=(ConvertTo-JsonText @($rows.Values))} -Procedure
        $coverage=@();$coverageComplete=$true
        if ($Config.checkTriggerCoverage) {
            $databases=@(Invoke-AuditSql $source 'SELECT name,state_desc,HAS_DBACCESS(name) AS HasAccess FROM sys.databases WHERE database_id>4 ORDER BY name;')
            $inspected=0
            foreach($db in $databases){
                if ($db.name -in @($Config.triggerCoverageExclusions)) {continue}
                if ($inspected -ge $Config.limits.coverageDatabasesPerRun) {$coverageComplete=$false;break}
                $inspected++
                if ($db.state_desc -ne 'ONLINE' -or $db.HasAccess -ne 1) {$coverage+=@{Database=$db.name;Status='Unknown';Reason='Database offline or inaccessible'};continue}
                # Quote database identifiers; never interpolate free-form source SQL.
                $quoted='['+$db.name.Replace(']',']]')+']'
                try {
                    $triggers=@(Invoke-AuditSql $source ("SELECT t.is_disabled,e.type_desc AS EventType FROM "+$quoted+".sys.triggers t LEFT JOIN "+$quoted+".sys.trigger_events e ON e.object_id=t.object_id WHERE t.parent_class=0 AND t.name=N'schema_change_tracking';"))
                    $expected=@('CREATE_PROCEDURE','ALTER_PROCEDURE','DROP_PROCEDURE','CREATE_TABLE','ALTER_TABLE','DROP_TABLE','CREATE_FUNCTION','ALTER_FUNCTION','DROP_FUNCTION','CREATE_VIEW','ALTER_VIEW','DROP_VIEW')
                    $found=@($triggers | Where-Object is_disabled -EQ $false | ForEach-Object EventType)
                    $missing=@($expected | Where-Object {$_ -notin $found})
                    $coverage+=@{Database=$db.name;Status=if($missing.Count){'GapOrMetadataHidden'}else{'OK'};MissingEvents=$missing}
                }catch{$coverage+=@{Database=$db.name;Status='Unknown';Reason='Cannot inspect trigger metadata'}}
            }
        }
        $coverageGaps=@($coverage | Where-Object Status -NE 'OK').Count
        return @{Status=if($coverageGaps -or -not $coverageComplete){'Attention'}else{'OK'};Rows=$rows.Count;NewCursor=$newCursor;ReconcileCursor=$reconcileCursor;MaxSourceId=$upper;Backlog=($newCursor -lt $upper);ReconciliationCycleComplete=($reconcileCursor -eq 0);IndexVerified=[bool]$meta[0].HasLogIdIndex;TriggerCoverage=$coverage;TriggerCoverageComplete=$coverageComplete;Reason=if($coverageGaps -or -not $coverageComplete){'Trigger coverage has gaps or incomplete metadata visibility; see central evidence'}else{''}}
    } finally { $source.Dispose() }
}
Export-ModuleMember -Function *
