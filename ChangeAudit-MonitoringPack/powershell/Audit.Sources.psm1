Import-Module "$PSScriptRoot\Audit.Core.psm1" -DisableNameChecking
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ReadHeaders([string]$SecretPath) {
    if (-not (Test-Path -LiteralPath $SecretPath)) { throw 'API credential file missing. Run Initialize-AuditCredentials.ps1 as the collector identity on its host.' }
    $secrets = Import-Clixml -LiteralPath $SecretPath
    if ($secrets.AzurePat -isnot [Management.Automation.PSCredential] -or $secrets.Jira -isnot [Management.Automation.PSCredential]) { throw 'Invalid credential file' }
    $az = ':' + $secrets.AzurePat.GetNetworkCredential().Password
    $jira = $secrets.Jira.UserName + ':' + $secrets.Jira.GetNetworkCredential().Password
    return @{
        Azure = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($az)); Accept = 'application/json' }
        Jira = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jira)); Accept = 'application/json' }
    }
}

function Invoke-ReadApi([string]$Uri, [hashtable]$Headers) {
    # All external operations in this module are GETs to these two configured services.
    $target = [uri]$Uri
    if ($target.Scheme -ne 'https' -or $target.Host -notin @('dev.azure.com','betsoftware.atlassian.net')) { throw 'Unexpected API destination' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try { return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -TimeoutSec 30 -MaximumRedirection 0 }
        catch {
            $code = 0
            if ($null -ne $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -in @(429,502,503,504) -and $attempt -lt 2) { Start-Sleep -Seconds (2 * ($attempt + 1)); continue }
            # Never emit response bodies or auth headers into job history.
            throw "Read API failed ($($target.Host), HTTP $code). Verify read permissions, credential expiry, and connectivity."
        }
    }
}

function Write-AtomicJson([string]$Path, $Value) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    $temporary = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-JsonText $Value), (New-Object Text.UTF8Encoding $false))
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                if ([IO.File]::Exists($fullPath)) { [IO.File]::Replace($temporary, $fullPath, [NullString]::Value) }
                else { [IO.File]::Move($temporary, $fullPath) }
                return
            } catch { if ($attempt -eq 4) { throw }; Start-Sleep -Milliseconds 200 }
        }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-RepositorySnapshot($Config, [hashtable]$Headers, [string[]]$Databases, [string]$CachePath) {
    $base = 'https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_apis/git/repositories/' + $Config.repositoryId
    $refs = Invoke-ReadApi "$base/refs?filter=heads/master&api-version=7.1" $Headers
    $ref = @($refs.value | Where-Object { $_.name -ceq 'refs/heads/master' })
    if ($ref.Count -ne 1) { throw 'Exactly one master ref was not returned' }
    $commit = [string]$ref[0].objectId
    if ($commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid master commit ID' }
    $tree = Invoke-ReadApi "$base/items?recursionLevel=Full&versionDescriptor.versionType=commit&versionDescriptor.version=$commit&api-version=7.1" $Headers
    if ($null -eq $tree.PSObject.Properties['value']) { throw 'Invalid repository tree response' }
    $artifacts = New-Object 'System.Collections.Generic.List[object]'
    $scopes = @{}; $downloads = 0
    foreach ($database in $Databases) {
        $mapping = @($Config.databaseFolderMappings | Where-Object { $_.database -ceq $database })
        $folder = if ($mapping.Count -eq 1) { [string]$mapping[0].folder } else { '/' + $database }
        # Exact folder match only; never fuzzy-map a different database.
        $exists = @($tree.value | Where-Object { $_.path -ceq $folder -and (Get-Value $_ 'isFolder' $false) }).Count -eq 1
        if (-not $exists) { $scopes[$database] = @{ Complete = $false; Reason = 'Exact database folder missing; configure mapping'; Folder = $folder }; continue }
        $items = @($tree.value | Where-Object { $_.path.StartsWith($folder + '/', [StringComparison]::Ordinal) -and $_.path.EndsWith('.sql', [StringComparison]::OrdinalIgnoreCase) -and -not (Get-Value $_ 'isFolder' $false) } | Sort-Object path)
        $complete = $items.Count -gt 0
        foreach ($item in $items) {
            $blob = [string]$item.objectId
            if ($blob -notmatch '^[0-9a-f]{40}$') { $complete = $false; continue }
            $cacheFile = Join-Path $CachePath ($blob + '.json')
            $cached = $null
            if (Test-Path -LiteralPath $cacheFile) {
                try {
                    $cached = Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json
                    if ($cached.Blob -cne $blob -or (Get-Hash $cached.Content) -cne $cached.Hash) { $cached = $null }
                } catch { $cached = $null }
            }
            if ($null -eq $cached) {
                if ($downloads -ge $Config.limits.repositoryFilesPerRun) { $complete = $false; continue }
                $path = [uri]::EscapeDataString($item.path)
                $file = Invoke-ReadApi "$base/items?path=$path&includeContent=true&versionDescriptor.versionType=commit&versionDescriptor.version=$commit&api-version=7.1" $Headers
                if ($null -eq $file.PSObject.Properties['content']) { $complete = $false; continue }
                $cached = @{ Blob = $blob; Content = [string]$file.content; Hash = Get-Hash ([string]$file.content) }
                Write-AtomicJson $cacheFile $cached
                $downloads++
            }
            $artifacts.Add([pscustomobject]@{ Database = $database; Path = $item.path; Commit = $commit; Blob = $blob; ContentHash = $cached.Hash; Content = $cached.Content; Parsed = Read-SqlEvidence $cached.Content $database })
        }
        $scopes[$database] = @{ Complete = $complete; Folder = $folder; Files = $items.Count; Reason = if ($complete) { 'All SQL files in folder read' } else { 'Repository indexing incomplete or empty; next run continues using immutable blob cache' } }
    }
    return @{ Commit = $commit; RetrievedAtUtc = [DateTime]::UtcNow.ToString('o'); Scopes = $scopes; Artifacts = $artifacts.ToArray() }
}

function Resolve-JiraFieldMap($Config, [hashtable]$Headers) {
    $fields = @(Invoke-ReadApi ($Config.rabSource.baseUrl + '/rest/api/3/field') $Headers)
    $mapping = @{}
    foreach ($property in $Config.rabSource.observedFieldLabels.PSObject.Properties) {
        $override = Get-Value $Config.rabSource.fieldMappings $property.Name
        $found = @(if ($override) { $fields | Where-Object { $_.id -ceq $override } } else { $fields | Where-Object { $_.name -ceq $property.Value } })
        if ($found.Count -eq 0 -and $property.Name -in @('rabApprover','rabApprovers')) { $mapping[$property.Name]='';continue }
        if ($found.Count -ne 1) { throw "Jira field '$($property.Value)' is missing or ambiguous; configure its exact field ID." }
        $mapping[$property.Name] = [string]$found[0].id
    }
    return $mapping
}

function Get-JiraSnapshot($Config, [hashtable]$Headers) {
    $base = $Config.rabSource.baseUrl
    $filter = Invoke-ReadApi ($base + '/rest/api/3/filter/' + $Config.rabSource.filterId) $Headers
    if ($filter.jql.Trim() -cne $Config.rabSource.verifiedFilterJql) { throw 'Saved Jira filter changed; review and update verifiedFilterJql before using absence results.' }
    $mapping = Resolve-JiraFieldMap $Config $Headers
    $jql = [uri]::EscapeDataString('filter = ' + $Config.rabSource.filterId + ' ORDER BY created DESC')
    $fieldList = @('summary','description','created','updated','status','environment') + @($mapping.Values)
    $encodedFields = [uri]::EscapeDataString(($fieldList -join ','))
    $issues = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $seenTokens = New-Object 'System.Collections.Generic.HashSet[string]'
    $token = ''; $complete = $false
    for ($page = 0; $page -lt $Config.limits.jiraPagesPerRun; $page++) {
        $uri = "$base/rest/api/3/search/jql?jql=$jql&fields=$encodedFields&maxResults=100"
        if ($token) { $uri += '&nextPageToken=' + [uri]::EscapeDataString($token) }
        $response = Invoke-ReadApi $uri $Headers
        if ($null -eq $response.PSObject.Properties['issues']) { throw 'Invalid Jira issue-search response' }
        foreach ($issue in $response.issues) { if ($seen.Add([string]$issue.id)) { $issues.Add($issue) } }
        $token = [string](Get-Value $response 'nextPageToken' '')
        if ((Get-Value $response 'isLast' $false) -eq $true) { $complete = $true; break }
        if (-not $token -or -not $seenTokens.Add($token)) { throw 'Jira pagination did not provide a new continuation token' }
    }
    return @{ Issues = $issues.ToArray(); FieldMap = $mapping; Complete = $complete; FilterJql = $filter.jql; RetrievedAtUtc = [DateTime]::UtcNow.ToString('o') }
}

function Get-JiraDetails([string]$Key, $Config, [hashtable]$Headers) {
    if ($Key -notmatch '^[A-Z][A-Z0-9_]*-\d+$') { throw 'Invalid Jira issue key' }
    $base = $Config.rabSource.baseUrl + '/rest/api/3/issue/' + $Key
    $result = @{}
    foreach ($kind in @('comment','changelog')) {
        $values = New-Object 'System.Collections.Generic.List[object]'
        $start = 0; $complete = $false
        for ($page = 0; $page -lt $Config.limits.jiraDetailPages; $page++) {
            $response = Invoke-ReadApi "$base/$($kind)?startAt=$start&maxResults=100" $Headers
            $items = @(Get-Value $response $(if ($kind -eq 'comment') { 'comments' } else { 'values' }) @())
            foreach ($item in $items) { $values.Add($item) }
            $start += $items.Count
            if ($null -eq $response.PSObject.Properties['total']) { throw 'Jira detail pagination total missing' }
            if ($start -ge [int]$response.total) { $complete = $true; break }
            if ($items.Count -eq 0) { throw 'Jira detail pagination stalled' }
        }
        $result[$kind] = $values.ToArray(); $result[$kind + 'Complete'] = $complete
    }
    return $result
}

function Get-PrEvidence([int]$Id, $Config, [hashtable]$Headers) {
    $base = 'https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_apis/git/repositories/' + $Config.repositoryId
    $pr = Invoke-ReadApi "$base/pullrequests/$($Id)?api-version=7.1" $Headers
    if ($pr.repository.id -cne $Config.repositoryId) { throw 'PR repository differs from configured SA repository' }
    $changes = New-Object 'System.Collections.Generic.List[object]'
    $complete = $false
    $artifactCommit=$null
    if ($pr.targetRefName -ceq 'refs/heads/master') {
        $target = [string](Get-Value (Get-Value $pr 'lastMergeTargetCommit') 'commitId')
        $artifactCommit = [string](Get-Value (Get-Value $pr $(if ($pr.status -eq 'completed') {'lastMergeCommit'} else {'lastMergeSourceCommit'})) 'commitId')
        if ($target -notmatch '^[0-9a-f]{40}$' -or $artifactCommit -notmatch '^[0-9a-f]{40}$') { throw 'PR commit evidence unavailable' }
        $skip = 0
        for ($page = 0; $page -lt $Config.limits.prChangePages; $page++) {
            $response = Invoke-ReadApi "$base/diffs/commits?baseVersion=$target&baseVersionType=commit&targetVersion=$artifactCommit&targetVersionType=commit&diffCommonCommit=false&`$top=100&`$skip=$skip&api-version=7.1" $Headers
            if ($null -eq $response.PSObject.Properties['changes']) { throw 'Invalid PR commit changes response' }
            foreach ($change in $response.changes) { $changes.Add($change) }
            $skip += @($response.changes).Count
            if ((Get-Value $response 'allChangesIncluded' $false) -eq $true) { $complete = $true; break }
            if (@($response.changes).Count -eq 0) { throw 'PR diff pagination ended without complete evidence' }
        }
    }
    return @{ PullRequest = $pr; Changes = $changes.ToArray(); Complete = $complete; ArtifactCommit=$artifactCommit }
}

function Get-PrFile([string]$Path, [string]$Commit, $Config, [hashtable]$Headers) {
    if ($Commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid PR commit' }
    $base = 'https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_apis/git/repositories/' + $Config.repositoryId
    $encoded = [uri]::EscapeDataString($Path)
    $file = Invoke-ReadApi "$base/items?path=$encoded&includeContent=true&versionDescriptor.versionType=commit&versionDescriptor.version=$Commit&api-version=7.1" $Headers
    if ($null -eq $file.PSObject.Properties['content']) { throw 'PR SQL content unavailable' }
    return [string]$file.content
}

Export-ModuleMember -Function *
