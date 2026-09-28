$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$installer = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "install.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw "install.ps1 has parser errors: $($errors[0].Message)" }

$function = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-WindowsArchitecture"
}, $true)
if (-not $function) { throw "Get-WindowsArchitecture was not found" }
Invoke-Expression $function.Extent.Text

$source = Get-Content -LiteralPath $installer -Raw
if ($source -match '(?im)^\s*\$RealBinary\s*=\s*Install-OfficialOpenCode') {
    throw "Install-OfficialOpenCode output must not be captured as the executable path"
}

$originalNative = $env:PROCESSOR_ARCHITEW6432
$originalProcess = $env:PROCESSOR_ARCHITECTURE
try {
    $cases = @(
        @{ Native = "AMD64"; Process = "x86"; Expected = "x64" },
        @{ Native = "ARM64"; Process = "AMD64"; Expected = "arm64" },
        @{ Native = $null; Process = "AMD64"; Expected = "x64" }
    )
    foreach ($case in $cases) {
        $env:PROCESSOR_ARCHITEW6432 = $case.Native
        $env:PROCESSOR_ARCHITECTURE = $case.Process
        $actual = Get-WindowsArchitecture
        if ($actual -ne $case.Expected) {
            throw "Expected $($case.Expected), got $actual"
        }
    }
} finally {
    $env:PROCESSOR_ARCHITEW6432 = $originalNative
    $env:PROCESSOR_ARCHITECTURE = $originalProcess
}

Write-Output "Windows installer compatibility tests passed."
