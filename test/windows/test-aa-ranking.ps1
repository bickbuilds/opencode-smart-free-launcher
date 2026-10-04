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

Write-Output ""
if ($script:Failures -gt 0) { Write-Output "$($script:Failures) check(s) failed."; exit 1 }
Write-Output "Windows AA ranking tests passed."