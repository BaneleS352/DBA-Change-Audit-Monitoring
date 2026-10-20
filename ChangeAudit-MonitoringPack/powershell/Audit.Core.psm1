Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-Hash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-JsonText($Value) { return ConvertTo-Json -InputObject $Value -Depth 80 -Compress }

function ConvertFrom-JiraDate($Text) {
    if ($Text -is [DateTimeOffset]) { return $Text.UtcDateTime }
    if ($Text -is [datetime]) {
        if ($Text.Kind -eq [DateTimeKind]::Unspecified) { throw 'Offset missing from parsed API timestamp' }
        return $Text.ToUniversalTime()
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    # Jira often emits +0200; explicitly normalize to the ISO offset form.
    $normalized = $Text -replace '([+-]\d{2})(\d{2})$', '$1:$2'
    if ($normalized -notmatch '(?:Z|[+-]\d{2}:\d{2})$') { throw 'Offset missing from API timestamp' }
    return [DateTimeOffset]::Parse($normalized, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

function Get-SastDayBounds([datetime]$NowUtc = [DateTime]::UtcNow) {
    $day = $NowUtc.ToUniversalTime().AddHours(2).Date
    return @{ Date = $day.ToString('yyyy-MM-dd'); StartLocal = $day; EndLocal = $day.AddDays(1); StartUtc = $day.AddHours(-2); EndUtc = $day.AddDays(1).AddHours(-2) }
}

function Get-AdfText($Node) {
    if ($null -eq $Node) { return '' }
    if ($Node -is [string]) { return $Node }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $text = Get-Value $Node 'text'
    if ($null -ne $text) { $parts.Add([string]$text) }
    foreach ($child in @(Get-Value $Node 'content' @())) { $parts.Add((Get-AdfText $child)) }
    $joined = $parts -join ''
    if ((Get-Value $Node 'type') -in @('paragraph','heading','listItem','codeBlock','hardBreak')) { $joined += "`n" }
    return $joined
}

function Get-AdfLinks($Node) {
    if ($null -eq $Node) { return }
    foreach ($mark in @(Get-Value $Node 'marks' @())) {
        if ((Get-Value $mark 'type') -eq 'link') { Get-Value (Get-Value $mark 'attrs') 'href' }
    }
    $url = Get-Value (Get-Value $Node 'attrs') 'url'
    if ($url) { $url }
    foreach ($child in @(Get-Value $Node 'content' @())) { Get-AdfLinks $child }
}

function Get-SaPullRequestIds($Issue, $FieldMap) {
    $fields = $Issue.fields
    $texts = @((Get-AdfText (Get-Value $fields 'description')))
    $texts += @(Get-AdfLinks (Get-Value $fields 'description'))
    foreach ($key in @('pullRequest','deploymentInstructions')) {
        $value = Get-Value $fields (Get-Value $FieldMap $key '')
        $texts += Get-AdfText $value
        $texts += @(Get-AdfLinks $value)
    }
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($text in $texts) {
        foreach ($match in [regex]::Matches([string]$text, 'https://dev\.azure\.com/BETSoftwareO365/SyX(?:%20| )SSDT/_git/SSDT_SA/pullrequest/(\d+)(?=[/?#\s<>"'']|$)', 'IgnoreCase')) {
            $null = $ids.Add([int]$match.Groups[1].Value)
        }
    }
    @($ids | Sort-Object)
}

function Initialize-SqlParser([string]$AssemblyPath) {
    if (-not ('Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -as [type])) {
        if (-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) { throw 'ScriptDom assembly not found. Set scriptDomPath to the installed Microsoft ScriptDom DLL.' }
        Add-Type -Path $AssemblyPath
    }
}

function Get-SqlTokens($Fragment, [switch]$Definition) {
    $tokens = New-Object 'System.Collections.Generic.List[string]'
    for ($i = $Fragment.FirstTokenIndex; $i -le $Fragment.LastTokenIndex; $i++) {
        $token = $Fragment.ScriptTokenStream[$i]
        $kind = [string]$token.TokenType
        if ($kind -in @('WhiteSpace','SingleLineComment','MultilineComment','EndOfFile')) { continue }
        # Preserve literals and identifiers exactly, including case. False negatives are safer than false matches.
        $value = [string]$token.Text
        if ($kind -eq 'QuotedIdentifier') {
            if ($value.StartsWith('[')) { $value=$value.Substring(1,$value.Length-2).Replace(']]',']') }
            elseif ($value.StartsWith('"')) { $value=$value.Substring(1,$value.Length-2).Replace('""','"') }
            $value='IDENTIFIER:'+$value
        } elseif ($kind -eq 'Identifier') { $value='IDENTIFIER:'+$value }
        elseif ($kind -eq 'Procedure') { $value='PROCEDURE' }
        elseif ($kind -notmatch 'Literal') { $value = $value.ToUpperInvariant() }
        $tokens.Add($value)
    }
    if ($Definition -and $tokens.Count -gt 0) {
        if ($tokens.Count -gt 2 -and $tokens[0] -eq 'CREATE' -and $tokens[1] -eq 'OR' -and $tokens[2] -eq 'ALTER') { $tokens.RemoveRange(0, 3) }
        elseif ($tokens[0] -in @('CREATE','ALTER')) { $tokens.RemoveAt(0) }
        $tokens.Insert(0, 'MODULE_DEFINITION')
    }
    # JSON token boundaries prevent removing a comment from merging two tokens.
    return Get-Hash (ConvertTo-JsonText $tokens.ToArray())
}

function Read-SqlEvidence([string]$Sql, [string]$Database) {
    $parser = New-Object Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser $true
    $errors = $null
    $reader = New-Object IO.StringReader $Sql
    try { $tree = $parser.Parse($reader, [ref]$errors) } finally { $reader.Dispose() }
    if ($errors.Count -gt 0) { return @{ Supported = $false; Reason = 'SQL parser errors or SQLCMD syntax'; Objects = @() } }
    $objects = New-Object 'System.Collections.Generic.List[object]'
    $contexts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($batch in $tree.Batches) {
        foreach ($statement in $batch.Statements) {
            $kind = $statement.GetType().Name
            if ($kind -eq 'UseStatement') {
                if ($statement.DatabaseName.Value -cne $Database) { return @{ Supported = $false; Reason = 'Database context differs or uses different case'; Objects = @() } }
                continue
            }
            if ($kind -eq 'PredicateSetStatement') {
                $contexts.Add((Get-SqlTokens $statement)); continue
            }
            $name = $null; $objectType = $null; $definition = $false
            if ($kind -match '^(Create|Alter|CreateOrAlter)ProcedureStatement$') { $name = $statement.ProcedureReference.Name; $objectType = 'PROCEDURE'; $definition = $true }
            elseif ($kind -match '^(Create|Alter|CreateOrAlter)ViewStatement$') { $name = $statement.SchemaObjectName; $objectType = 'VIEW'; $definition = $true }
            elseif ($kind -match '^(Create|Alter|CreateOrAlter)FunctionStatement$') { $name = $statement.Name; $objectType = 'FUNCTION'; $definition = $true }
            elseif ($kind -match '^CreateTableStatement$|^AlterTable.*Statement$') { $name = Get-Value $statement 'SchemaObjectName'; $objectType = 'TABLE' }
            elseif ($kind -match '^Drop(Procedure|View|Function|Table)Statement$') {
                $objectType = $Matches[1].ToUpperInvariant()
                if ($statement.Objects.Count -ne 1) { return @{ Supported = $false; Reason = 'Multi-object DROP needs review'; Objects = @() } }
                $name = $statement.Objects[0]
            }
            else { return @{ Supported = $false; Reason = "Unsupported top-level SQL: $kind"; Objects = @() } }
            if ($null -eq $name -or $name.Identifiers.Count -ne 2) { return @{ Supported = $false; Reason = 'Explicit two-part schema/object identity required'; Objects = @() } }
            $operation = if ($kind.StartsWith('Drop')) { 'DROP' } elseif ($kind.StartsWith('Alter')) { 'ALTER' } elseif ($kind.StartsWith('CreateOrAlter')) { 'CREATE_OR_ALTER' } else { 'CREATE' }
            $objects.Add([pscustomobject]@{
                Schema = $name.Identifiers[0].Value; Name = $name.Identifiers[1].Value; ObjectType = $objectType
                Operation = $operation; StatementHash = Get-SqlTokens $statement
                DefinitionHash = if ($definition) { Get-SqlTokens $statement -Definition } else { $null }
                ContextHash = Get-Hash ($contexts -join '|')
            })
        }
    }
    return @{ Supported = $true; Reason = ''; Objects = $objects.ToArray() }
}

function Compare-RepositoryEvidence($Event, $Artifacts, [bool]$Complete) {
    $source = Read-SqlEvidence $Event.SqlCommand $Event.DatabaseName
    if (-not $source.Supported -or $source.Objects.Count -ne 1) { return @{ Status = 'NeedsReview'; Reason = 'Captured batch requires manual SQL review'; Matches = @() } }
    $obj = $source.Objects[0]
    $eventAgrees=($obj.Operation + '_' + $obj.ObjectType) -eq $Event.EventType
    if ($obj.Operation -eq 'CREATE_OR_ALTER') { $eventAgrees=$Event.EventType -in @(('CREATE_'+$obj.ObjectType),('ALTER_'+$obj.ObjectType)) }
    if ($obj.Schema -cne $Event.SchemaName -or $obj.Name -cne $Event.ObjectName -or -not $eventAgrees) {
        return @{ Status = 'NeedsReview'; Reason = 'Captured identity/event type differs from parsed statement'; Matches = @() }
    }
    $matches = @(); $candidates = @(); $unsupported = $false; $contextMismatch=$false
    foreach ($artifact in $Artifacts) {
        $parsed = $artifact.Parsed
        if (-not $parsed.Supported) { $unsupported = $true; continue }
        foreach ($candidate in $parsed.Objects) {
            if ($candidate.Schema -cne $obj.Schema -or $candidate.Name -cne $obj.Name -or $candidate.ObjectType -ne $obj.ObjectType) { continue }
            $candidates += $artifact.Path
            if ($candidate.ContextHash -ne $obj.ContextHash) { $contextMismatch=$true;continue }
            $method = $null
            if ($candidate.StatementHash -eq $obj.StatementHash) { $method = 'StatementMatch' }
            elseif ($obj.DefinitionHash -and $candidate.DefinitionHash -eq $obj.DefinitionHash) { $method = 'DefinitionMatch' }
            if ($method) { $matches += [pscustomobject]@{ Path = $artifact.Path; Commit = $artifact.Commit; Method = $method; ContentHash = $artifact.ContentHash } }
        }
    }
    if ($matches.Count -gt 0) { return @{ Status = 'Matched'; Reason = 'Matches current pinned master content; historical deployment provenance assessed separately'; Matches = $matches } }
    if (-not $Complete) { return @{ Status = 'Unknown'; Reason = 'Repository scope not fully fetched'; Matches = @() } }
    if ($unsupported -or $contextMismatch -or $obj.Operation -eq 'DROP' -or ($obj.ObjectType -eq 'TABLE' -and $obj.Operation -eq 'ALTER')) {
        return @{ Status = 'NeedsReview'; Reason = 'Unsupported scripts or deployment operation needs migration evidence'; Matches = @() }
    }
    if ($candidates.Count) { return @{ Status = 'Different'; Reason = 'Object found, but supported SQL/context does not match'; Matches = @() } }
    return @{ Status = 'NotFound'; Reason = 'Object not found in the completely read mapped folder'; Matches = @() }
}

# Approval validity is deliberately left to the DBA. No allowlist or approval decision engine.
function Get-ApprovalDisplay($Issue, $Details, $FieldMap) {
    $people=@()
    foreach($key in @('rabApprover','rabApprovers')) {
        foreach($person in @(Get-Value $Issue.fields (Get-Value $FieldMap $key '') @())) {
            if($null -ne $person) {
                $people += [pscustomobject]@{Name=[string](Get-Value $person 'displayName' 'Name unavailable');AccountId=[string](Get-Value $person 'accountId');Field=$key}
            }
        }
    }
    $comments=@()
    foreach($comment in @(Get-Value $Details 'comment' @())) {
        $comments += [pscustomobject]@{
            Id=[string]$comment.id
            Author=[string](Get-Value (Get-Value $comment 'author') 'displayName' 'Name unavailable')
            Created=[string](Get-Value $comment 'created')
            Updated=[string](Get-Value $comment 'updated')
            Text=Get-AdfText (Get-Value $comment 'body')
        }
    }
    return @{Mode='ManualReview';Approvers=$people;Comments=$comments;CommentsComplete=[bool](Get-Value $Details 'commentComplete' $false);Notice='Names and comments are recorded evidence only. The DBA verifies approval validity and timing.'}
}

Export-ModuleMember -Function *
