$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$launcher = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "windows\opencode-smart.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw "opencode-smart.ps1 has parser errors: $($errors[0].Message)" }

# Load only the config constants and function definitions, so no launcher
# entrypoint logic (binary discovery, cache writes, exec) runs during tests.
$configNames = @(
    "CatalogUrl", "StatsUrl", "AaApiUrl", "AaApiKeyEnv", "AaPageSize",
    "HealthyTtlSeconds", "FallbackTtlSeconds", "AaIndexFields", "AaIdSuffixes",
    "ConfigPath", "CacheDir", "CachePath", "Subcommands", "ResumeFlags",
    "PassthroughFlags", "FallbackPreference"
)
$definitions = @()
foreach ($node in $ast.EndBlock.Statements) {
    if ($node -is [Management.Automation.Language.AssignmentStatementAst]) {
        $name = $node.Left.Extent.Text.TrimStart('$')
        if ($configNames -contains $name) { $definitions += $node.Extent.Text }
    } elseif ($node -is [Management.Automation.Language.FunctionDefinitionAst]) {
        $definitions += $node.Extent.Text
    }
}
# LOCALAPPDATA is Windows-only; the launcher derives its cache paths from it.
$env:LOCALAPPDATA = Join-Path ([System.IO.Path]::GetTempPath()) "opencode-smart-tests"
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null
Invoke-Expression ($definitions -join "`n")

$script:Failures = 0
function Assert-Equal($Name, $Actual, $Expected) {
    if ($Actual -eq $Expected) { Write-Output "ok   $Name" }
    else { Write-Output "FAIL $Name : got '$Actual' want '$Expected'"; $script:Failures++ }
}

# Strips Zen-only distribution qualifiers instead of relying on a hardcoded alias.
$keys = @(Get-AaMatchKeys ([pscustomobject]@{ id = "muse-spark-1.3-contributor-free"; name = "Muse Spark 1.3 Free"; context = 100 }))
Assert-Equal "contributor tier matches publisher name" ($keys -contains "musespark13contributor") $true
Assert-Equal "full id is also offered"                 ($keys -contains "musespark13contributorfree") $true

$keys = @(Get-AaMatchKeys ([pscustomobject]@{ id = "longcat-2.5-preview-free"; name = "LongCat 2.5 Preview Free"; context = 50 }))
Assert-Equal "preview tier is stripped" ($keys -contains "longcat25preview") $true

# Coding and Intelligence indices are separately calibrated and must not be mixed.
$scores = @{
    highcoding       = [pscustomobject]@{ aa_name = "High Coding"; indices = [ordered]@{
        artificial_analysis_coding_index       = 90.0
        artificial_analysis_intelligence_index = 10.0 } }
    highintelligence = [pscustomobject]@{ aa_name = "High Intelligence"; indices = [ordered]@{
        artificial_analysis_intelligence_index = 95.0 } }
}
$candidates = @(
    [pscustomobject]@{ id = "high-coding"; name = "High Coding"; context = 100 },
    [pscustomobject]@{ id = "high-intelligence"; name = "High Intelligence"; context = 100 }
)
$ranked = Select-ByAa $candidates $scores
Assert-Equal "coding index wins over a higher intelligence index" $ranked.candidate.id "high-coding"
Assert-Equal "reports the coding field" $ranked.score.aa_field "artificial_analysis_coding_index"
Assert-Equal "reports the coding value" $ranked.score.aa_index 90.0
# aa_name must be the publisher's name, not the Zen display name.
Assert-Equal "reports the publisher name" $ranked.score.aa_name "High Coding"

# Falls through to the next field when the preferred one is absent.
$ranked = Select-ByAa @([pscustomobject]@{ id = "only-intel"; name = "Only Intel"; context = 10 }) @{
    onlyintel = [pscustomobject]@{ aa_name = "Only Intel"; indices = [ordered]@{
        artificial_analysis_intelligence_index = 42.0 } }
}
Assert-Equal "falls back to the intelligence field" $ranked.score.aa_field "artificial_analysis_intelligence_index"
Assert-Equal "falls back to the intelligence value" $ranked.score.aa_index 42.0

# A missing key must degrade with an actionable message, not silently mis-rank.
$savedKey = $env:ARTIFICIAL_ANALYSIS_API_KEY
try {
    $env:ARTIFICIAL_ANALYSIS_API_KEY = ""
    $threw = $false
    try { $null = Get-AaApiKey } catch { $threw = $true; $message = $_.Exception.Message }
    Assert-Equal "missing key throws" $threw $true
    Assert-Equal "missing key names the variable" ($message -like "*ARTIFICIAL_ANALYSIS_API_KEY*") $true
} finally {
    $env:ARTIFICIAL_ANALYSIS_API_KEY = $savedKey
}

# A clean ranking must still disclose models the publisher never scored.
$coverageCandidates = @(
    [pscustomobject]@{ id = "muse-free"; name = "Muse"; context = 100 },
    [pscustomobject]@{ id = "space-bunny-free"; name = "Bunny"; context = 100 }
)
$coverage = Select-ByAa $coverageCandidates @{
    muse = [pscustomobject]@{ aa_name = "Muse"; indices = [ordered]@{ artificial_analysis_coding_index = 75.0 } }
}
Assert-Equal "clean ranking still selected"  $coverage.candidate.id "muse-free"
Assert-Equal "unscored model is named"        ($coverage.score.unscored_ids -contains "space-bunny-free") $true

# End-to-end ranking against the real current free-model set.
$ranked = Select-ByAa @(
    [pscustomobject]@{ id = "muse-spark-1.3-contributor-free"; name = "Muse Spark 1.3 Free"; context = 1048576 },
    [pscustomobject]@{ id = "mimo-v2.6-flash-free"; name = "MiMo-V2.6-Flash Free"; context = 200000 }
) @{
    musespark13contributor = [pscustomobject]@{ aa_name = "Muse Spark 1.3 Contributor"; indices = [ordered]@{ artificial_analysis_coding_index = 48.0 } }
    mimov26flash           = [pscustomobject]@{ aa_name = "MiMo-V2.6-Flash";           indices = [ordered]@{ artificial_analysis_coding_index = 38.0 } }
}
Assert-Equal "best-scoring free model wins" $ranked.candidate.id "muse-spark-1.3-contributor-free"

# A base model must never donate its score to a distinct Flash/Lightning/Tiny variant.
$variantScores = @{
    mimov26 = [pscustomobject]@{ aa_name = "MiMo V2.6"; indices = [ordered]@{ artificial_analysis_coding_index = 99.0 } }
    mimov26flash = [pscustomobject]@{ aa_name = "MiMo V2.6 Flash"; indices = [ordered]@{ artificial_analysis_coding_index = 38.0 } }
    competitor = [pscustomobject]@{ aa_name = "Competitor"; indices = [ordered]@{ artificial_analysis_coding_index = 50.0 } }
}
$flash = [pscustomobject]@{ id = "mimo-v2.6-flash-free"; name = "MiMo V2.6 Flash Free"; context = 200 }
Assert-Equal "exact variant gets its own score" (Get-AaScore $flash $variantScores).aa_name "MiMo V2.6 Flash"
$ranked = Select-ByAa @($flash, [pscustomobject]@{ id = "competitor"; name = "Competitor"; context = 100 }) $variantScores
Assert-Equal "base score cannot change the winner" $ranked.candidate.id "competitor"
foreach ($variant in @("flash", "lightning", "tiny")) {
    $candidate = [pscustomobject]@{ id = "mimo-v2.6-$variant-free"; name = "MiMo V2.6 $variant Free" }
    Assert-Equal "$variant cannot match the base model" (Get-AaScore $candidate @{ mimov26 = $variantScores.mimov26 }) $null
}
Assert-Equal "exact display name precedes stripped id" (Get-AaScore ([pscustomobject]@{
    id = "muse-contributor-free"; name = "Publisher Name"
}) @{
    muse = [pscustomobject]@{ aa_name = "Muse" }
    publishername = [pscustomobject]@{ aa_name = "Publisher Name" }
}).aa_name "Publisher Name"
Assert-Equal "contributor precedes base alias" (Get-AaScore ([pscustomobject]@{
    id = "muse-contributor-free"; name = "Muse Free"
}) @{
    muse = [pscustomobject]@{ aa_name = "Muse" }
    musecontributor = [pscustomobject]@{ aa_name = "Muse Contributor" }
}).aa_name "Muse Contributor"

# Exercise the real numeric response parser and refresh/cache path without network calls.
$originalPayload = ${function:Get-AaIndexPayload}
$originalCacheDir = $CacheDir
$originalCachePath = $CachePath
$testCacheDir = Join-Path $env:LOCALAPPDATA ([guid]::NewGuid().ToString())
try {
    function Get-AaIndexPayload {
        return ('{"intelligence_index_version":4.3,"models":[' +
            '{"name":"Coding Only","slug":"coding-only","evaluations":{' +
            '"artificial_analysis_coding_index":70.5,"artificial_analysis_agentic_index":false}},' +
            '{"name":"Intelligence Only","slug":"intelligence-only","evaluations":{' +
            '"artificial_analysis_intelligence_index":90}}]}') | ConvertFrom-Json
    }
    function Invoke-RestMethod {
        return ('{"opencode":{"models":{' +
            '"coding-only-free":{"name":"Coding Only Free","cost":{"input":0,"output":0},"tool_call":true,"limit":{"context":100}},' +
            '"intelligence-only-free":{"name":"Intelligence Only Free","cost":{"input":0,"output":0},"tool_call":true,"limit":{"context":100}},' +
            '"unscored-free":{"name":"Unscored Free","cost":{"input":0,"output":0},"tool_call":true,"limit":{"context":100}}}}}') | ConvertFrom-Json
    }
    function Invoke-WebRequest { throw "usage fallback should not need the network in this test" }
    $snapshot = Get-AaIndexSnapshot
    Assert-Equal "numeric API index is parsed" $snapshot.scores.codingonly.indices.artificial_analysis_coding_index 70.5
    Assert-Equal "boolean API value is not an index" $snapshot.scores.codingonly.indices.Contains("artificial_analysis_agentic_index") $false
    $selection = [pscustomobject](Refresh-Selection)
    Assert-Equal "numeric response stays on benchmark ranking" $selection.ranking_source "aa-api"
    Assert-Equal "refresh preserves selected index" $selection.aa_index 70.5
    Assert-Equal "coverage counts both index families" $selection.benchmarked_count 2
    Assert-Equal "ranking counts only the chosen index" $selection.ranked_count 1
    Assert-Equal "refresh preserves unscored ids" ($selection.unscored_ids -join ',') "unscored-free"

    $CacheDir = $testCacheDir
    $CachePath = Join-Path $CacheDir "selection.json"
    New-Item -ItemType Directory -Path $CacheDir | Out-Null
    $legacy = [pscustomobject]@{
        schema = 1; model = "opencode/legacy"; name = "Legacy"; basis = "Ebbwater AA Index"
        ranking_source = "ebbwater-aa"; aa_index = 40; selected_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    $legacy | ConvertTo-Json | Set-Content -LiteralPath $CachePath -Encoding UTF8
    $selection = Get-Selection $false
    Assert-Equal "legacy healthy cache forces refresh" $selection.cache "refreshed"
    Assert-Equal "legacy source is replaced" $selection.ranking_source "aa-api"
    $status = Show-Status $selection
    Assert-Equal "refreshed cache can show status" ($status -contains "AA index: 70.5 (source: artificial_analysis_coding_index)") $true

    function Invoke-RestMethod { throw "offline" }
    Assert-Equal "current cache avoids network" (Get-Selection $false).cache "fresh"
    $legacy | ConvertTo-Json | Set-Content -LiteralPath $CachePath -Encoding UTF8
    $threw = $false
    try { $null = Get-Selection $false } catch { $threw = $true; $message = $_.Exception.Message }
    Assert-Equal "legacy cache is not reused on refresh failure" $threw $true
    Assert-Equal "refresh failure is preserved" $message "offline"

    $fallback = [pscustomobject]@{
        schema = 1; model = "opencode/fallback"; ranking_source = "fallback"
        selected_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    $fallback | ConvertTo-Json | Set-Content -LiteralPath $CachePath -Encoding UTF8
    Assert-Equal "current fallback cache remains usable" (Get-Selection $false).cache "fresh"
} finally {
    Set-Item Function:\Get-AaIndexPayload -Value $originalPayload
    Remove-Item Function:\Invoke-RestMethod
    Remove-Item Function:\Invoke-WebRequest
    $CacheDir = $originalCacheDir
    $CachePath = $originalCachePath
    if (Test-Path -LiteralPath $testCacheDir) { Remove-Item -LiteralPath $testCacheDir -Recurse -Force }
}

Write-Output ""
if ($script:Failures -gt 0) { Write-Output "$($script:Failures) check(s) failed."; exit 1 }
Write-Output "Windows AA ranking tests passed."
