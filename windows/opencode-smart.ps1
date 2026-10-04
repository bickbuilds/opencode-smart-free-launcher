$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$CatalogUrl = "https://models.dev/api.json"
$StatsUrl = "https://stats.opencode.ai/"
$AaApiUrl = "https://artificialanalysis.ai/api/v2/language/models/free"
$AaApiKeyEnv = "ARTIFICIAL_ANALYSIS_API_KEY"
$AaPageSize = 200
$HealthyTtlSeconds = 24 * 60 * 60
$FallbackTtlSeconds = 60 * 60
# The Coding Agent Index is the closest published analogue to how this launcher
# ranks: it weights DeepSWE, Terminal-Bench 4.0 and SWE-Atlas-QnA. Each entry is
# tried in order, so a model missing the preferred index still ranks on the next.
$AaIndexFields = @("artificial_analysis_coding_index", "artificial_analysis_agentic_index", "artificial_analysis_intelligence_index")
# Zen-only distribution qualifiers, peeled off when matching a Zen id against a
# benchmark publisher's model name.
$AaIdSuffixes = @("-free", "-preview", "-contributor", "-lightning", "-flash", "-tiny")
$ConfigPath = Join-Path $env:LOCALAPPDATA "opencode-smart-launcher\config.json"
$CacheDir = Join-Path $env:LOCALAPPDATA "opencode-free-launcher"
$CachePath = Join-Path $CacheDir "selection.json"
$Subcommands = @("acp", "api", "auth", "debug", "mcp", "mini", "models", "pair", "plugin", "reload", "run", "serve", "service", "session", "stats", "uninstall", "update", "upgrade")
$ResumeFlags = @("--continue", "-c", "--session", "-s")
$PassthroughFlags = @("--help", "-h", "--version", "-v", "--completions")
$FallbackPreference = @("space-bunny-free", "deepseek-v4-flash-free", "muse-spark-1.3-contributor-free", "mimo-v2.6-flash-free", "nemotron-3-ultra-free", "longcat-2.5-preview-free")

function Fail([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("OpenCode free launcher: $Message")
    exit $Code
}

function Get-RealBinary {
    if ($env:OPENCODE_REAL_BINARY -and (Test-Path -LiteralPath $env:OPENCODE_REAL_BINARY)) {
        return $env:OPENCODE_REAL_BINARY
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            if ($config.real_binary -and (Test-Path -LiteralPath $config.real_binary)) {
                return [string]$config.real_binary
            }
        } catch {}
    }
    Fail "real OpenCode executable not found; rerun install.ps1 or set OPENCODE_REAL_BINARY" 127
}

function Get-ModelKey([string]$Value) {
    return ($Value.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Get-FreeCandidates($Catalog) {
    $result = @()
    foreach ($property in $Catalog.opencode.models.PSObject.Properties) {
        $id = [string]$property.Name
        $model = $property.Value
        if ($model.cost.input -ne 0 -or $model.cost.output -ne 0 -or $model.tool_call -ne $true) { continue }
        $status = if ($model.PSObject.Properties["status"]) { [string]$model.status } else { "" }
        if ($status -eq "deprecated" -or $id.StartsWith("jev-")) { continue }
        $context = 0
        if ($model.limit -and $model.limit.context) { $context = [long]$model.limit.context }
        $name = if ($model.name) { [string]$model.name } else { $id }
        $result += [pscustomobject]@{ id = $id; name = $name; context = $context }
    }
    if ($result.Count -eq 0) { throw "No tool-capable zero-cost OpenCode Zen models are currently listed" }
    return $result
}

function Get-AaApiKey {
    $value = [string][Environment]::GetEnvironmentVariable($AaApiKeyEnv)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$AaApiKeyEnv is not set; get a free key at https://artificialanalysis.ai/data-api"
    }
    return $value.Trim()
}

function Get-AaIndexPayload {
    $headers = @{ "x-api-key" = (Get-AaApiKey); "Accept" = "application/json" }
    $models = @()
    $version = $null
    $page = 1
    while ($true) {
        $url = "$AaApiUrl`?page=$page&page_size=$AaPageSize"
        $body = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20
        if ($null -eq $body.data) { throw "Artificial Analysis response had no model list" }
        $models += @($body.data)
        if ($null -ne $body.intelligence_index_version) { $version = $body.intelligence_index_version }
        if ($null -eq $body.pagination) { throw "Artificial Analysis response had no pagination block" }
        if (-not $body.pagination.has_more) { break }
        $page++
        if ($page -gt 50) { throw "Artificial Analysis pagination did not terminate" }
    }
    if ($models.Count -eq 0) { throw "Artificial Analysis returned no language models" }
    return [pscustomobject]@{ models = $models; intelligence_index_version = $version }
}

function Get-AaIndexSnapshot {
    # Freshness is implicit: this is a live API call, so the existing 24h selection
    # cache bounds how old a decision can be. There is no page timestamp to police,
    # which is what previously forced a hard fallback when a mirror went quiet.
    $payload = Get-AaIndexPayload
    $scores = @{}
    foreach ($row in $payload.models) {
        $evaluationsProperty = $row.PSObject.Properties["evaluations"]
        if ($null -eq $evaluationsProperty -or $null -eq $evaluationsProperty.Value) { continue }
        $evaluations = $evaluationsProperty.Value
        $indices = [ordered]@{}
        foreach ($field in $AaIndexFields) {
            $property = $evaluations.PSObject.Properties[$field]
            if ($null -ne $property -and $property.Value -is [ValueType] -and -not [bool]::IsNaN([double]$property.Value)) {
                $indices[$field] = [double]$property.Value
            }
        }
        if ($indices.Count -eq 0) { continue }
        foreach ($nameProperty in @($row.PSObject.Properties["name"], $row.PSObject.Properties["slug"])) {
            if ($null -eq $nameProperty) { continue }
            $rawName = [string]$nameProperty.Value
            if ([string]::IsNullOrWhiteSpace($rawName)) { continue }
            $key = Get-ModelKey $rawName
            if (-not $scores.ContainsKey($key)) {
                $scores[$key] = [pscustomobject]@{ aa_name = $rawName; indices = $indices }
            }
        }
    }
    if ($scores.Count -eq 0) { throw "Artificial Analysis returned no usable index scores" }
    return [pscustomobject]@{ scores = $scores; intelligence_index_version = $payload.intelligence_index_version }
}

function Get-AaMatchKeys($Candidate) {
    $keys = @()
    foreach ($field in @("id", "name")) {
        $value = [string]$Candidate.$field
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $keys += Get-ModelKey $value
        $current = $value
        while ($true) {
            $stripped = $false
            foreach ($suffix in $AaIdSuffixes) {
                if ($current.EndsWith($suffix)) {
                    $current = $current.Substring(0, $current.Length - $suffix.Length)
                    $keys += Get-ModelKey $current
                    $stripped = $true
                    break
                }
            }
            if (-not $stripped) { break }
        }
    }
    return $keys | Where-Object { $_ } | Select-Object -Unique
}

function Get-AaScore($Candidate, $Scores) {
    foreach ($key in (Get-AaMatchKeys $Candidate | Sort-Object)) {
        if ($Scores.ContainsKey($key)) { return $Scores[$key] }
    }
    return $null
}

function Select-ByAa($Candidates, $Scores) {
    $matched = @()
    foreach ($candidate in $Candidates) {
        $score = Get-AaScore $candidate $Scores
        if ($null -ne $score) { $matched += [pscustomobject]@{ candidate = $candidate; score = $score } }
    }
    if ($matched.Count -eq 0) { throw "Artificial Analysis has no index scores matching the current free models" }

    # Rank on a single index across all candidates. The Coding, Agentic and
    # Intelligence indices are separately calibrated, so mixing them in one
    # comparison would compare incomparable numbers.
    foreach ($field in $AaIndexFields) {
        $ranked = @($matched | Where-Object { $_.score.indices.Contains($field) -and $_.score.indices[$field] -ne $null })
        if ($ranked.Count -eq 0) { continue }
        $best = $ranked | Sort-Object @{ Expression = { [double]$_.score.indices[$field] }; Descending = $true },
                                     @{ Expression = { [long]$_.candidate.context }; Descending = $true },
                                     @{ Expression = { [string]$_.candidate.id }; Descending = $false } |
                   Select-Object -First 1
        $scoredIds = @($ranked | ForEach-Object { $_.candidate.id } | Select-Object -Unique)
        $anyMatchedIds = @($matched | ForEach-Object { $_.candidate.id } | Select-Object -Unique)
        return [pscustomobject]@{
            candidate = $best.candidate
            score = [pscustomobject]@{
                aa_index = [double]$best.score.indices[$field]; aa_field = $field; aa_name = $best.score.aa_name
                ranked_count = $scoredIds.Count
                # Every free candidate the publisher did not score at all, so a
                # popular but unbenchmarked model is disclosed rather than dropped.
                unscored_ids = @($Candidates | Where-Object { $anyMatchedIds -notcontains $_.id } | ForEach-Object { $_.id } | Sort-Object)
            }
        }
    }
    throw "Artificial Analysis returned no comparable index scores"
}

function Get-UsageScores([string]$Html) {
    $scores = @{}
    $pattern = 'model:"(?<model>[a-zA-Z0-9._-]+)"[^{}]{0,220}?tokens:(?<tokens>[0-9.]+)[^{}]{0,120}?rank:[0-9]+'
    foreach ($match in [regex]::Matches($Html, $pattern)) {
        $id = $match.Groups["model"].Value
        $tokens = [double]$match.Groups["tokens"].Value
        if (-not $scores.ContainsKey($id) -or $tokens -gt $scores[$id]) { $scores[$id] = $tokens }
    }
    return $scores
}

function Get-UsageKey([string]$Id) {
    if ($Id.EndsWith("-contributor-free")) { return $Id.Substring(0, $Id.Length - 5) }
    if ($Id.EndsWith("-free")) { return $Id.Substring(0, $Id.Length - 5) }
    return $Id
}

function Select-Fallback($Candidates, $UsageScores) {
    $best = $null
    $bestUsage = 0.0
    foreach ($candidate in $Candidates) {
        $key = Get-UsageKey $candidate.id
        $usage = if ($UsageScores.ContainsKey($key)) { [double]$UsageScores[$key] } else { 0.0 }
        if ($null -eq $best -or $usage -gt $bestUsage -or ($usage -eq $bestUsage -and $candidate.context -gt $best.context)) {
            $best = $candidate; $bestUsage = $usage
        }
    }
    if ($bestUsage -gt 0) { return [pscustomobject]@{ candidate = $best; basis = "OpenCode public weekly usage" } }
    foreach ($id in $FallbackPreference) {
        $match = $Candidates | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if ($match) { return [pscustomobject]@{ candidate = $match; basis = "verified fallback preference" } }
    }
    $best = $Candidates | Sort-Object context, id -Descending | Select-Object -First 1
    return [pscustomobject]@{ candidate = $best; basis = "verified context-size fallback" }
}

function Refresh-Selection {
    $now = [DateTimeOffset]::UtcNow
    $catalog = Invoke-RestMethod -Uri $CatalogUrl -TimeoutSec 20
    $candidates = @(Get-FreeCandidates $catalog)
    try {
        $snapshot = Get-AaIndexSnapshot
        $ranked = Select-ByAa $candidates $snapshot.scores
        $shortField = $ranked.score.aa_field -replace '^artificial_analysis_', '' -replace '_index$', ''
        # Coverage spans every free candidate, not just the ones carrying the
        # ranking index, so a partially benchmarked catalog stays visible.
        $matchedIds = @($candidates | Where-Object { $null -ne (Get-AaScore $_ $snapshot.scores) } | ForEach-Object { $_.id })
        return [ordered]@{
            schema = 1; model = "opencode/$($ranked.candidate.id)"; name = $ranked.candidate.name
            basis = "Artificial Analysis $shortField"; ranking_source = "aa-api"
            intelligence_index_version = $snapshot.intelligence_index_version
            aa_index = $ranked.score.aa_index; aa_field = $ranked.score.aa_field; aa_name = $ranked.score.aa_name
            ranked_count = $ranked.score.ranked_count; benchmarked_count = $matchedIds.Count
            candidate_count = $candidates.Count
            unscored_ids = @($candidates | Where-Object { $matchedIds -notcontains $_.id } | ForEach-Object { $_.id } | Sort-Object)
            selected_at = $now.ToUnixTimeSeconds()
        }
    } catch {
        $reason = $_.Exception.Message
        try { $usage = Get-UsageScores ((Invoke-WebRequest -Uri $StatsUrl -UseBasicParsing -TimeoutSec 20).Content) } catch { $usage = @{} }
        $ranked = Select-Fallback $candidates $usage
        return [ordered]@{
            schema = 1; model = "opencode/$($ranked.candidate.id)"; name = $ranked.candidate.name
            basis = "FALLBACK: $($ranked.basis)"; ranking_source = "fallback"
            fallback_reason = $reason; candidate_count = $candidates.Count
            selected_at = $now.ToUnixTimeSeconds()
        }
    }
}

function Get-Selection([bool]$ForceRefresh) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $mutex = New-Object Threading.Mutex($false, "Local\OpenCodeSmartFreeSelection")
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(30))) { throw "timed out waiting for the selection cache" }
    try {
        $cached = $null
        $fresh = $false
        if (Test-Path -LiteralPath $CachePath) {
            try { $cached = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json } catch {}
        }
        if ($cached) {
            $ttl = if ($cached.ranking_source -eq "fallback") { $FallbackTtlSeconds } else { $HealthyTtlSeconds }
            $fresh = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$cached.selected_at) -lt $ttl
            if (-not $ForceRefresh -and $fresh) { $cached | Add-Member -NotePropertyName cache -NotePropertyValue "fresh" -Force; return $cached }
        }
        try { $selected = Refresh-Selection } catch {
            if ($cached -and $fresh) { $cached | Add-Member -NotePropertyName cache -NotePropertyValue "refresh-failed" -Force; return $cached }
            throw
        }
        $temporary = "$CachePath.$PID.tmp"
        $selected | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -Force -LiteralPath $temporary -Destination $CachePath
        $result = [pscustomobject]$selected
        $result | Add-Member -NotePropertyName cache -NotePropertyValue "refreshed" -Force
        return $result
    } finally {
        $mutex.ReleaseMutex(); $mutex.Dispose()
    }
}

function Test-Noninteractive([string[]]$Arguments) {
    foreach ($arg in $Arguments) { if ($PassthroughFlags -contains $arg) { return $true } }
    foreach ($arg in $Arguments) {
        if ($arg -eq "--") { return $false }
        if (-not $arg.StartsWith("-") -and $Subcommands -contains $arg) { return $true }
    }
    return $false
}

function Get-TargetDirectory([string[]]$Arguments) {
    $takesValue = @("--server", "--prompt", "--log-level", "--session", "-s")
    $skip = $false
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($skip) { $skip = $false; continue }
        if ($takesValue -contains $arg) { $skip = $true; continue }
        if ($arg -eq "--" -and $i + 1 -lt $Arguments.Count) { return [IO.Path]::GetFullPath($Arguments[$i + 1]) }
        if (-not $arg.StartsWith("-")) { return [IO.Path]::GetFullPath($arg) }
    }
    return (Get-Location).Path
}

function ConvertTo-NativeJsonArgument([string]$Json) {
    # Windows PowerShell 5.1 and PowerShell's pre-7.3 native argument mode
    # remove embedded quotes when constructing an executable command line.
    # OpenCode then receives invalid JSON. Modern Windows/Standard mode keeps
    # the quotes and must receive the original string.
    $mode = Get-Variable -Name PSNativeCommandArgumentPassing -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $mode -or [string]$mode.Value -eq "Legacy") {
        return $Json.Replace('"', '\"')
    }
    return $Json
}

function Show-Status($Selection) {
    $fallback = $Selection.ranking_source -eq "fallback"
    Write-Output "OpenCode free-model status"
    Write-Output $(if ($fallback) { "Health: DEGRADED - FALLBACK ACTIVE" } else { "Health: OK - Artificial Analysis ranking active" })
    Write-Output "Model: $($Selection.name) ($($Selection.model))"
    Write-Output "Ranking: $($Selection.basis)"
    if ($Selection.PSObject.Properties["aa_index"]) { Write-Output "AA index: $($Selection.aa_index) (source: $($Selection.aa_field))" }
    if ($Selection.PSObject.Properties["intelligence_index_version"]) { Write-Output "AA Intelligence Index version: $($Selection.intelligence_index_version)" }
    # A successful ranking says nothing about models the publisher has not
    # scored, so surface them rather than implying full coverage.
    if ($Selection.PSObject.Properties["unscored_ids"] -and @($Selection.unscored_ids).Count -gt 0) {
        Write-Output "Coverage: $($Selection.benchmarked_count) of $($Selection.candidate_count) free models scored by AA"
        Write-Output "Not scored by AA ($(@($Selection.unscored_ids).Count)): $(@($Selection.unscored_ids) -join ', ')"
    }
    if ($Selection.PSObject.Properties["fallback_reason"]) { Write-Output "Fallback reason: $($Selection.fallback_reason)" }
    Write-Output "Cache: $($Selection.cache)"
}

$RealBinary = Get-RealBinary
$Arguments = @($args)
if (@($Arguments | Where-Object { $ResumeFlags -contains $_ }).Count -gt 0 -or (Test-Noninteractive $Arguments)) {
    & $RealBinary @Arguments
    exit $LASTEXITCODE
}

$DryRun = $Arguments -contains "--smart-free-dry-run"
$Status = $Arguments -contains "--smart-free-status"
$ForceRefresh = $Arguments -contains "--smart-free-refresh"
$Arguments = @($Arguments | Where-Object { $_ -notin @("--smart-free-dry-run", "--smart-free-status", "--smart-free-refresh") })
try { $Selection = Get-Selection $ForceRefresh } catch { Fail $_.Exception.Message }

if ($DryRun) { [pscustomobject]@{ action = "launch"; selection = $Selection } | ConvertTo-Json -Depth 8; exit 0 }
if ($Status) { Show-Status $Selection; exit 0 }

try {
    $parts = $Selection.model.Split('/', 2)
    $payload = @{
        model = @{ providerID = $parts[0]; id = $parts[1] }
        location = @{ directory = (Get-TargetDirectory $Arguments) }
    } | ConvertTo-Json -Compress -Depth 5
    $nativePayload = ConvertTo-NativeJsonArgument $payload
    $raw = (& $RealBinary api session.create --data $nativePayload | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "OpenCode session API exited with code $LASTEXITCODE" }
    $session = ($raw | ConvertFrom-Json).data
    if ($session.model.providerID -ne $parts[0] -or $session.model.id -ne $parts[1]) { throw "OpenCode created the session with a different model than requested" }
} catch { Fail "could not create an explicit-model OpenCode session: $($_.Exception.Message)" }

if ($Selection.ranking_source -eq "fallback") {
    [Console]::Error.WriteLine("WARNING: Artificial Analysis ranking unavailable - FALLBACK ACTIVE.")
    [Console]::Error.WriteLine("Reason: $($Selection.fallback_reason)")
} else {
    [Console]::Error.WriteLine("Artificial Analysis ranking active: $($Selection.aa_index) ($($Selection.aa_field), index v$($Selection.intelligence_index_version)).")
}
[Console]::Error.WriteLine("OpenCode free launcher: $($Selection.name) ($($Selection.model)) via $($Selection.basis) [$($Selection.cache)].")
[Console]::Error.WriteLine("Free-model session: do not submit private or confidential material.")
& $RealBinary --session $session.id @Arguments
exit $LASTEXITCODE
