[CmdletBinding()]
param([string]$ConfigPath="$PSScriptRoot\..\config\target.json",[switch]$Scheduled)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\Audit.Core.psm1" -DisableNameChecking
Import-Module "$PSScriptRoot\Audit.Sql.psm1" -DisableNameChecking
Import-Module "$PSScriptRoot\Audit.Sources.psm1" -DisableNameChecking
Import-Module "$PSScriptRoot\Audit.Reconcile.psm1" -DisableNameChecking
$config=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($Scheduled -and -not $config.scheduledCollectionEnabled) { throw 'Scheduled collection is disabled in configuration.' }
if ($config.sourceTimeZoneId -ne 'South Africa Standard Time' -or -not $config.sourceGeneration) { throw 'Source timezone/generation must be explicitly configured.' }
$central=New-AuditConnection $config.centralServer $config.centralDatabase
$runId=$null; $lockAcquired=$false; $exitCode=0
try {
    $central.Open()
    $lock=@(Invoke-AuditSql $central "DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=N'DBAChangeAuditCollector',@LockMode=N'Exclusive',@LockOwner=N'Session',@LockTimeout=0; SELECT @r AS Result;")
    if ($lock[0].Result -lt 0) { throw 'Another collector is running; this run did not start.' }
    $lockAcquired=$true
    $run=@(Invoke-AuditSql $central 'dbo.usp_BeginRun' -Procedure); $runId=[long]$run[0].RunId
    $health=[ordered]@{Source=@{Status='Unknown'};Repository=@{Status='Unknown'};Display=@{Status='OK'}}
    $assessments=@(); $snapshot=[ordered]@{Configuration=$config;ConfigHash=Get-Hash (Get-Content -LiteralPath $ConfigPath -Raw)}
    try { $health.Source=Read-AuditSource $config $central } catch { $health.Source=@{Status='Error';Reason=$_.Exception.Message};$exitCode=1 }
    $bounds=Get-SastDayBounds
    $events=@(Invoke-AuditSql $central 'dbo.usp_ReadToday' @{StartUtc=$bounds.StartUtc;EndUtc=$bounds.EndUtc;Limit=10001;DatabaseName=$config.repositoryDatabase} -Procedure)
    if ($events.Count -gt 10000) { $health.Display=@{Status='Incomplete';Reason='More than 10000 events today; export capped'};$events=@($events | Select-Object -First 10000);$exitCode=1 }

    $repo=$null;$headers=$null
    try {
        Initialize-SqlParser $config.scriptDomPath
        $headers=New-ReadHeaders $config.credentialPath
    } catch { $health.Repository=@{Status='Error';Reason=$_.Exception.Message};$exitCode=1 }
    if ($headers) {
        try {
            $repo=Get-RepositorySnapshot $config $headers.Azure @($config.repositoryDatabase) (Join-Path $config.cachePath 'blobs')
            $health.Repository=@{Status='OK';RepositoryId=$repo.RepositoryId;RepositoryName=$repo.RepositoryName;Branch=$repo.Branch;Commit=$repo.Commit;Scopes=$repo.Scopes};$snapshot.Repository=$repo
            if (@($repo.Scopes.Values | Where-Object { -not $_.Complete }).Count) { $health.Repository.Status='Indexing' }
        } catch { $health.Repository=@{Status='Error';Reason=$_.Exception.Message};$exitCode=1 }
    }
    foreach ($event in $events) {
        $repository=@{Status='Unknown';Reason='Repository evidence unavailable';Matches=@()}
        if ($repo) {
            $scope=Get-Value $repo.Scopes $event.DatabaseName
            $repository=Compare-RepositoryEvidence $event @($repo.Artifacts | Where-Object Database -CEQ $event.DatabaseName) ([bool](Get-Value $scope 'Complete' $false))
            $repository.Commit=$repo.Commit;$repository.Branch=$repo.Branch
        }
        $eventUtc=[datetime]::SpecifyKind($event.EventAtUtc,[DateTimeKind]::Utc)
        $assessments += [pscustomobject]@{EventId=$event.EventId;RepositoryStatus=$repository.Status;RabStatus='Deferred';OverallStatus=Get-RepositoryOverallStatus $repository.Status $eventUtc $config.evidenceGraceMinutes;EvidenceJson=@{Repository=$repository;AssessedAtUtc=[DateTime]::UtcNow.ToString('o')}}
    }
    $status=if ($exitCode) {'Error'} elseif ($health.Source.Status -ne 'OK' -or $health.Repository.Status -ne 'OK' -or (Get-Value $health.Source 'Backlog' $false)) {'Attention'} else {'OK'}
    $null=Invoke-AuditSql $central 'dbo.usp_CompleteRun' @{RunId=$runId;Status=$status;HealthJson=(ConvertTo-JsonText $health);AssessmentsJson=(ConvertTo-JsonText @($assessments));EvidenceJson=(ConvertTo-JsonText $snapshot)} -Procedure -Timeout 120
    $dashboard=@(Invoke-AuditSql $central 'dbo.usp_DashboardJson' @{DatabaseName=$config.repositoryDatabase} -Procedure)
    Write-AtomicJson $config.dashboardJsonPath ($dashboard[0].DashboardJson | ConvertFrom-Json)
    Write-Output "Change audit run $runId completed: $status. Today's events assessed: $($events.Count)."
} catch {
    if ($runId -and $central.State -eq [Data.ConnectionState]::Open) {
        try {
            $failure=@{Collector=@{Status='Error';Reason='Run interrupted. Check SQL Agent history and collector-host logs.'}}
            $null=Invoke-AuditSql $central 'dbo.usp_CompleteRun' @{RunId=$runId;Status='Error';HealthJson=(ConvertTo-JsonText $failure);AssessmentsJson='[]';EvidenceJson='{}'} -Procedure
        } catch { Write-Warning 'Unable to mark the interrupted run centrally; stale-data detection remains active.' }
    }
    throw
} finally { $central.Dispose() }
if ($exitCode) { exit 1 }
