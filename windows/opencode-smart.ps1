$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$CatalogUrl = "https://models.dev/api.json"
$StatsUrl = "https://stats.opencode.ai/"
$EbbwaterUrl = "https://www.ebbwater.net/tools/opencode"
$HealthyTtlSeconds = 24 * 60 * 60
$FallbackTtlSeconds = 60 * 60
$EbbwaterMaxAgeSeconds = 3 * 24 * 60 * 60
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

function Get-EbbwaterSnapshot([string]$Html, [DateTimeOffset]$Now) {
    $updatedMatch = [regex]::Match($Html, 'var AA_UPDATED = "([^"]+)";')
    $rosterMatch = [regex]::Match($Html, 'var ZEN = (\[.*?\]);\s*/\* Coding Agent Index', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $updatedMatch.Success -or -not $rosterMatch.Success) { throw "Ebbwater page did not contain the expected AA snapshot" }
    $updated = [DateTimeOffset]::Parse($updatedMatch.Groups[1].Value)
    $age = ($Now - $updated).TotalSeconds
    if ($age -lt -300 -or $age -gt $EbbwaterMaxAgeSeconds) { throw "Ebbwater AA snapshot is stale ($([math]::Max(0, [math]::Floor($age / 3600))) hours old)" }
    $scores = @{}
    foreach ($row in ($rosterMatch.Groups[1].Value | ConvertFrom-Json)) {
        if ($row.Count -lt 3 -or $null -eq $row[1]) { continue }
        $scores[(Get-ModelKey ([string]$row[0]))] = [pscustomobject]@{
            aa_index = [double]$row[1]
            aa_position = if ($null -ne $row[2]) { [double]$row[2] } else { $null }
        }
    }
    return [pscustomobject]@{ scores = $scores; updated_at = $updatedMatch.Groups[1].Value }
}

function Get-AaScore($Candidate, $Scores) {
    $keys = @((Get-ModelKey $Candidate.id), (Get-ModelKey $Candidate.name))
    if ($Candidate.id -eq "muse-spark-1.3-contributor-free") { $keys += (Get-ModelKey "Muse Spark 1.3 Contributor Free") }
    foreach ($key in $keys) { if ($Scores.ContainsKey($key)) { return $Scores[$key] } }
    return $null
}

function Select-ByAa($Candidates, $Scores) {
    $best = $null
    $bestScore = $null
    foreach ($candidate in $Candidates) {
        $score = Get-AaScore $candidate $Scores
        if ($null -eq $score) { continue }
        $position = if ($null -ne $score.aa_position) { [double]$score.aa_position } else { 1000000000 }
        $bestPosition = if ($null -ne $bestScore -and $null -ne $bestScore.aa_position) { [double]$bestScore.aa_position } else { 1000000000 }
        if ($null -eq $best -or $score.aa_index -gt $bestScore.aa_index -or
            ($score.aa_index -eq $bestScore.aa_index -and $position -lt $bestPosition) -or
            ($score.aa_index -eq $bestScore.aa_index -and $position -eq $bestPosition -and $candidate.context -gt $best.context)) {
            $best = $candidate
            $bestScore = $score
        }
    }
    if ($null -eq $best) { throw "Ebbwater has no AA scores matching the current free models" }
    return [pscustomobject]@{ candidate = $best; score = $bestScore }
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
        $html = (Invoke-WebRequest -Uri $EbbwaterUrl -UseBasicParsing -TimeoutSec 20).Content
        $snapshot = Get-EbbwaterSnapshot $html $now
        $ranked = Select-ByAa $candidates $snapshot.scores
        return [ordered]@{
            schema = 1; model = "opencode/$($ranked.candidate.id)"; name = $ranked.candidate.name
            basis = "Ebbwater AA Index"; ranking_source = "ebbwater-aa"
            source_updated_at = $snapshot.updated_at; aa_index = $ranked.score.aa_index
            aa_position = $ranked.score.aa_position; candidate_count = $candidates.Count
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

function Show-Status($Selection) {
    $fallback = $Selection.ranking_source -eq "fallback"
    Write-Output "OpenCode free-model status"
    Write-Output $(if ($fallback) { "Health: DEGRADED - FALLBACK ACTIVE" } else { "Health: OK - Ebbwater AA ranking active" })
    Write-Output "Model: $($Selection.name) ($($Selection.model))"
    Write-Output "Ranking: $($Selection.basis)"
    if ($Selection.PSObject.Properties["aa_index"]) { Write-Output "AA index: $($Selection.aa_index) (AA position #$($Selection.aa_position))" }
    if ($Selection.PSObject.Properties["source_updated_at"]) { Write-Output "Ebbwater snapshot: $($Selection.source_updated_at)" }
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
    $raw = (& $RealBinary api session.create --data $payload | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "OpenCode session API exited with code $LASTEXITCODE" }
    $session = ($raw | ConvertFrom-Json).data
    if ($session.model.providerID -ne $parts[0] -or $session.model.id -ne $parts[1]) { throw "OpenCode created the session with a different model than requested" }
} catch { Fail "could not create an explicit-model OpenCode session: $($_.Exception.Message)" }

if ($Selection.ranking_source -eq "fallback") {
    [Console]::Error.WriteLine("WARNING: Ebbwater AA ranking unavailable - FALLBACK ACTIVE.")
    [Console]::Error.WriteLine("Reason: $($Selection.fallback_reason)")
} else {
    [Console]::Error.WriteLine("Ebbwater AA ranking active: index $($Selection.aa_index) (snapshot $($Selection.source_updated_at)).")
}
[Console]::Error.WriteLine("OpenCode free launcher: $($Selection.name) ($($Selection.model)) via $($Selection.basis) [$($Selection.cache)].")
[Console]::Error.WriteLine("Free-model session: do not submit private or confidential material.")
& $RealBinary --session $session.id @Arguments
exit $LASTEXITCODE
