Import-Module "$PSScriptRoot\Audit.Core.psm1" -DisableNameChecking
Import-Module "$PSScriptRoot\Audit.Sources.psm1" -DisableNameChecking
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Test-ScopeText([string]$Text, [string]$Server, [string]$Database, [string[]]$Aliases=@()) {
    $servers=@($Server)+@($Aliases)
    # Require an explicit Server: ... DB/Database: ... pair in the same segment.
    # Co-occurrence anywhere in a multi-country release is not enough.
    $segments=[regex]::Matches($Text,'(?is)(?:^|\b)Server\s*:\s*(?<server>[A-Z0-9_\\.-]+)(?<body>.*?)(?=\bServer\s*:|$)')
    foreach($segment in $segments){
        if($segment.Groups['server'].Value -notin $servers){continue}
        $db=[regex]::Match($segment.Groups['body'].Value,'(?i)\b(?:DB|Database)\s*:\s*\[?(?<database>[A-Z0-9_]+)\]?')
        if($db.Success -and $db.Groups['database'].Value -ceq $Database){return $true}
    }
    return $false
}

function Get-RabVerdict($Event, $Candidates, [bool]$DiscoveryComplete, $Config) {
    if ($Candidates.Count -eq 0) {
        if ($DiscoveryComplete) { return @{Status='NotFoundInScope';Reason='No matching SQL artifact found among accessible releases in filter 10528';Candidates=@()} }
        return @{Status='Unknown';Reason='Release/PR evidence scan incomplete';Candidates=@()}
    }
    $results=@()
    $eventUtc=[datetime]::SpecifyKind([datetime]$Event.EventAtUtc,[DateTimeKind]::Utc)
    foreach ($candidate in $Candidates) {
        $issue=$candidate.Issue; $mapping=$candidate.FieldMap
        $status='NeedsReview'; $reason='Release candidate requires review'; $approval=$null
        $scope=(Get-AdfText (Get-Value $issue.fields 'description'))+"`n"+(Get-AdfText (Get-Value $issue.fields $mapping.deploymentInstructions))
        $start=ConvertFrom-JiraDate (Get-Value $issue.fields $mapping.deploymentStart)
        $end=ConvertFrom-JiraDate (Get-Value $issue.fields $mapping.deploymentEnd)
        if (-not $candidate.ArtifactMatches) { $reason='PR references this object, but SQL content does not match the captured change' }
        elseif (-not (Test-ScopeText $scope $Config.sourceServer $Event.DatabaseName @($Config.approvedServerAliases))) { $reason='Exact server/database scope absent; possible server typo or ambiguous release scope' }
        elseif ($null -eq $start -or $null -eq $end) { $reason='Deployment start or end missing; cannot establish execution window' }
        elseif ($end -lt $start -or $eventUtc -lt $start -or $eventUtc -gt $end) { $status='OutsideWindow';$reason='SQL event is outside the recorded deployment window' }
        else {
            $status='Linked';$reason='Matching release artifact and execution scope/window. Approval validity must be verified by the DBA.'
        }
        $approval=Get-ApprovalDisplay $issue $candidate.Details $mapping
        $results += [pscustomobject]@{Key=$issue.key;Url=$Config.rabSource.baseUrl+'/browse/'+$issue.key;PrId=(Get-Value $candidate.Pr 'pullRequestId');Status=$status;Reason=$reason;Approval=$approval}
    }
    $linked=@($results | Where-Object Status -eq 'Linked')
    if ($linked.Count) { return @{Status='Linked';Reason='Release evidence linked; approval not validated by the tool';Candidates=$results} }
    if (-not $DiscoveryComplete) { return @{Status='Unknown';Reason='Candidate exceptions found; remaining release evidence incomplete';Candidates=$results} }
    $status=if (@($results | Where-Object Status -eq 'NeedsReview').Count) { 'NeedsReview' } else { $results[0].Status }
    return @{Status=$status;Reason='Release evidence requires review; approval validity is checked manually';Candidates=$results}
}

function Get-ReleaseCandidates($Events, $Jira, $Repository, $Config, $Headers, [string]$CachePath) {
    $byEvent=@{}; foreach ($event in $Events) { $byEvent[[string]$event.EventId]=@() }
    $complete=[bool]$Jira.Complete; $readCount=0; $fileCount=0; $errors=@();$unlinked=0
    $prCache=@{}; $detailCache=@{}; $fileCache=@{}
    foreach ($issue in $Jira.Issues) {
        $prIds=@(Get-SaPullRequestIds $issue $Jira.FieldMap)
        # Plain-text mentions are review candidates, never proof of matching SQL.
        if ($prIds.Count -eq 0) {
            $unlinked++
            $description=(Get-AdfText (Get-Value $issue.fields 'description'))+' '+[string]$issue.fields.summary+' '+(Get-AdfText (Get-Value $issue.fields $Jira.FieldMap.deploymentInstructions))
            foreach ($event in $Events) {
                if ($description -imatch ('(?<![\w])'+[regex]::Escape($event.ObjectName)+'(?![\w])')) {
                    $byEvent[[string]$event.EventId] += [pscustomobject]@{Issue=$issue;Pr=$null;Details=$null;FieldMap=$Jira.FieldMap;ArtifactMatches=$false;Path=$null;Commit=$null}
                }
            }
            continue
        }
        foreach ($id in $prIds) {
            try {
                if (-not $prCache.ContainsKey($id)) {
                    $diskPath=Join-Path $CachePath ('pr-'+$id+'.json')
                    $cached=$null
                    if (Test-Path -LiteralPath $diskPath) {
                        try {
                            $cached=Get-Content -LiteralPath $diskPath -Raw | ConvertFrom-Json
                            if ((Get-Hash (ConvertTo-JsonText $cached.Data)) -ne $cached.Hash) { $cached=$null }
                            # Short cache only. Completed metadata can still change and must be refreshed.
                            elseif (([DateTime]::UtcNow-(ConvertFrom-JiraDate $cached.RetrievedAtUtc)).TotalMinutes -gt $(if ($cached.Data.PullRequest.status -eq 'completed') {$Config.limits.completedPrCacheMinutes} else {$Config.limits.prCacheMinutes})) { $cached=$null }
                        } catch { $cached=$null }
                    }
                    if ($null -eq $cached) {
                        if ($readCount -ge $Config.limits.pullRequestsPerRun) { $complete=$false; continue }
                        $data=Get-PrEvidence $id $Config $Headers.Azure; $readCount++
                        Write-AtomicJson $diskPath @{Data=$data;Hash=Get-Hash (ConvertTo-JsonText $data);RetrievedAtUtc=[DateTime]::UtcNow.ToString('o')}
                        $prCache[$id]=$data
                    } else { $prCache[$id]=$cached.Data }
                }
                $evidence=$prCache[$id]; $pr=$evidence.PullRequest
                if (-not $evidence.Complete) { $complete=$false; continue }
                foreach ($event in $Events) {
                    $scope=Get-Value $Repository.Scopes $event.DatabaseName
                    if ($null -eq $scope) { $complete=$false;continue }
                    foreach ($change in $evidence.Changes) {
                        $path=[string](Get-Value (Get-Value $change 'item') 'path' '')
                        if (-not $path.StartsWith($scope.Folder+'/',[StringComparison]::Ordinal) -or -not $path.EndsWith('.sql',[StringComparison]::OrdinalIgnoreCase)) { continue }
                        if ([string]$change.changeType -match 'delete') { $complete=$false;continue }
                        $merge=[string]$evidence.ArtifactCommit
                        $fileKey=$merge+'|'+$path
                        if (-not $fileCache.ContainsKey($fileKey)) {
                            $sqlCachePath=Join-Path $CachePath ('sql-'+(Get-Hash $fileKey)+'.json')
                            $savedFile=$null
                            if (Test-Path -LiteralPath $sqlCachePath) {
                                try {
                                    $savedFile=Get-Content -LiteralPath $sqlCachePath -Raw | ConvertFrom-Json
                                    if ($savedFile.Commit -cne $merge -or $savedFile.Path -cne $path -or (Get-Hash $savedFile.Content) -cne $savedFile.Hash) { $savedFile=$null }
                                } catch {$savedFile=$null}
                            }
                            if ($null -eq $savedFile) {
                                if ($fileCount -ge $Config.limits.prFilesPerRun) { $complete=$false;continue }
                                $content=Get-PrFile $path $merge $Config $Headers.Azure; $fileCount++
                                Write-AtomicJson $sqlCachePath @{Commit=$merge;Path=$path;Content=$content;Hash=Get-Hash $content}
                            } else { $content=[string]$savedFile.Content }
                            $fileCache[$fileKey]=[pscustomobject]@{Path=$path;Commit=$merge;Content=$content;ContentHash=Get-Hash $content;Parsed=Read-SqlEvidence $content $event.DatabaseName}
                        }
                        $artifact=$fileCache[$fileKey]
                        if (-not $artifact.Parsed.Supported) { $complete=$false;continue }
                        $identity=@($artifact.Parsed.Objects | Where-Object { $_.Schema -ceq $event.SchemaName -and $_.Name -ceq $event.ObjectName })
                        if ($identity.Count -eq 0) { continue }
                        if (-not $detailCache.ContainsKey($issue.key)) { $detailCache[$issue.key]=Get-JiraDetails $issue.key $Config $Headers.Jira }
                        $comparison=Compare-RepositoryEvidence $event @($artifact) $true
                        $byEvent[[string]$event.EventId] += [pscustomobject]@{Issue=$issue;Pr=$pr;Details=$detailCache[$issue.key];FieldMap=$Jira.FieldMap;ArtifactMatches=($comparison.Status -eq 'Matched');Path=$path;Commit=$merge}
                    }
                }
            } catch { $complete=$false; $errors += "PR $id evidence unavailable" }
        }
    }
    return @{ByEvent=$byEvent;Complete=$complete;Errors=$errors;UnlinkedReleaseCount=$unlinked;PrEvidence=@($prCache.Values);Details=$detailCache;Files=@($fileCache.Values)}
}

function Get-OverallStatus([string]$Repository, [string]$Rab, [datetime]$EventUtc, [int]$GraceMinutes, [datetime]$NowUtc=[DateTime]::UtcNow) {
    if ($EventUtc.Kind -eq [DateTimeKind]::Local) { $EventUtc=$EventUtc.ToUniversalTime() }
    if ($NowUtc.Kind -eq [DateTimeKind]::Local) { $NowUtc=$NowUtc.ToUniversalTime() }
    if ($Repository -eq 'Matched' -and $Rab -eq 'Linked') { return 'EvidenceLinked' }
    if (($NowUtc-$EventUtc).TotalMinutes -lt $GraceMinutes) { return 'Pending' }
    $repoGap=$Repository -in @('Different','NotFound')
    $rabGap=$Rab -in @('NotFoundInScope','NotApproved','ApprovalAfterChange','LoggedAfterChange','OutsideWindow')
    if ($repoGap -and $rabGap) { return 'BothExceptions' }
    if ($repoGap) { return 'RepositoryException' }
    if ($rabGap) { return 'RabException' }
    return 'NeedsReview'
}
Export-ModuleMember -Function *
