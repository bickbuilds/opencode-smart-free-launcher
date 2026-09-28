$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$launcher = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "windows\opencode-smart.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw "opencode-smart.ps1 has parser errors: $($errors[0].Message)" }

$function = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "ConvertTo-NativeJsonArgument"
}, $true)
if (-not $function) { throw "ConvertTo-NativeJsonArgument was not found" }
Invoke-Expression $function.Extent.Text

$json = '{"model":{"providerID":"opencode","id":"test-free"}}'
$originalMode = Get-Variable -Name PSNativeCommandArgumentPassing -Scope Global -ErrorAction SilentlyContinue
try {
    Set-Variable -Name PSNativeCommandArgumentPassing -Scope Global -Value "Legacy"
    $legacy = ConvertTo-NativeJsonArgument $json
    if ($legacy -ne '{\"model\":{\"providerID\":\"opencode\",\"id\":\"test-free\"}}') {
        throw "Legacy native argument escaping was incorrect: $legacy"
    }

    Set-Variable -Name PSNativeCommandArgumentPassing -Scope Global -Value "Standard"
    $standard = ConvertTo-NativeJsonArgument $json
    if ($standard -ne $json) { throw "Standard native argument mode changed the JSON payload" }
} finally {
    if ($null -eq $originalMode) {
        Remove-Variable -Name PSNativeCommandArgumentPassing -Scope Global -ErrorAction SilentlyContinue
    } else {
        Set-Variable -Name PSNativeCommandArgumentPassing -Scope Global -Value $originalMode.Value
    }
}

Write-Output "Windows launcher native-argument tests passed."
