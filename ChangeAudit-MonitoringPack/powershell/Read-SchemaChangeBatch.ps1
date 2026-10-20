# Read-only page reader; not a scheduled collector or durable watermark implementation.
[CmdletBinding()]
param(
    [string]$SourceServer = 'HSB-SYX20-SQL01',
    [ValidateRange(0, 2147483647)]
    [int]$AfterLogId = 0,
    [ValidateRange(1, 1000)]
    [int]$BatchSize = 100,
    [ValidateRange(1, 120)]
    [int]$CommandTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$builder.DataSource = $SourceServer
$builder.InitialCatalog = 'DBA'
$builder.IntegratedSecurity = $true
$builder.Encrypt = $true
$builder.TrustServerCertificate = $false
$builder.ConnectTimeout = 10
$builder.ApplicationName = 'DBA Change Audit - Read Only Discovery'
$connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
$command = $connection.CreateCommand()
$command.CommandTimeout = $CommandTimeoutSeconds
# Use committed reads. Never use NOLOCK or READPAST for evidence capture.
$command.CommandText = @'
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET LOCK_TIMEOUT 5000;
SELECT TOP (@BatchSize)
    LogId, DatabaseName, EventType, SchemaName, ObjectName,
    ObjectType, SqlCommand, EventDate, LoginName
FROM dbo.__schema_change_tracking
WHERE LogId > @AfterLogId
ORDER BY LogId;
'@
$null = $command.Parameters.Add('@BatchSize', [System.Data.SqlDbType]::Int)
$command.Parameters['@BatchSize'].Value = $BatchSize
$null = $command.Parameters.Add('@AfterLogId', [System.Data.SqlDbType]::Int)
$command.Parameters['@AfterLogId'].Value = $AfterLogId
$reader = $null
try {
    $connection.Open()
    $reader = $command.ExecuteReader()
    # Buffer this bounded batch so a read failure does not emit a partial page.
    $rows = New-Object 'System.Collections.Generic.List[object]'
    while ($reader.Read()) {
        $record = [ordered]@{ SourceServer = $SourceServer }
        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
            $value = $reader.GetValue($i)
            if ($value -is [DBNull]) { $value = $null }
            $record[$reader.GetName($i)] = $value
        }
        # Explicitly leave local event time unconverted until timezone is verified.
        $record['CollectedAtUtc'] = [DateTime]::UtcNow
        $record['RepositoryStatus'] = 'NotAssessed'
        $record['RabStatus'] = 'NotAssessed'
        $rows.Add([pscustomobject]$record)
    }
    $rows.ToArray()
}
finally {
    if ($null -ne $reader) { $reader.Dispose() }
    $command.Dispose()
    $connection.Dispose()
}
