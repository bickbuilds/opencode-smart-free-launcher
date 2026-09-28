param(
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallRoot = Join-Path $env:LOCALAPPDATA "Programs\opencode-smart-launcher"
$BinDir = Join-Path $InstallRoot "bin"
$ManagedOpenCodeDir = Join-Path $env:LOCALAPPDATA "Programs\opencode-v2\bin"
$ConfigDir = Join-Path $env:LOCALAPPDATA "opencode-smart-launcher"
$ConfigPath = Join-Path $ConfigDir "config.json"
$SourceDir = Join-Path $PSScriptRoot "windows"
$GitBashBinDir = Join-Path $HOME "bin"
$GitBashShimMarker = "# managed-by: opencode-smart-launcher"

function Set-UserPath([string[]]$Entries) {
    [Environment]::SetEnvironmentVariable("Path", ($Entries -join ';'), "User")
}

function Remove-LauncherPath {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $BinDir.TrimEnd('\') })
    Set-UserPath $entries
}

function Test-ManagedGitBashShim([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try { return (Get-Content -LiteralPath $Path -Raw).Contains($GitBashShimMarker) } catch { return $false }
}

if ($Uninstall) {
    Remove-LauncherPath
    foreach ($name in @("opencode", "opencode-free")) {
        $shimPath = Join-Path $GitBashBinDir $name
        if (Test-ManagedGitBashShim $shimPath) { Remove-Item -LiteralPath $shimPath -Force }
    }
    if (Test-Path -LiteralPath $InstallRoot) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force }
    if (Test-Path -LiteralPath $ConfigPath) { Remove-Item -LiteralPath $ConfigPath -Force }
    if (Test-Path -LiteralPath $ConfigDir) {
        try { Remove-Item -LiteralPath $ConfigDir -Force } catch {}
    }
    Write-Output "OpenCode Smart Free Launcher removed. The underlying OpenCode installation was kept."
    exit 0
}

foreach ($required in @("opencode-smart.ps1", "opencode.cmd", "opencode-free.cmd", "opencode", "opencode-free")) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $required))) {
        throw "$required is missing from the windows directory beside install.ps1"
    }
}

function Find-ExistingOpenCode {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $saved = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            if ($saved.real_binary -and (Test-Path -LiteralPath $saved.real_binary)) { return [string]$saved.real_binary }
        } catch {}
    }
    foreach ($known in @(
        (Join-Path $HOME ".opencode\bin\opencode.exe"),
        (Join-Path $ManagedOpenCodeDir "opencode.exe")
    )) {
        if (Test-Path -LiteralPath $known) { return $known }
    }
    foreach ($command in @(Get-Command opencode -All -ErrorAction SilentlyContinue)) {
        $path = if ($command.Path) { [string]$command.Path } else { [string]$command.Source }
        if ($path -and -not $path.StartsWith($InstallRoot, [StringComparison]::OrdinalIgnoreCase)) { return $path }
    }
    return $null
}

function Convert-HexToBase64([string]$Hex) {
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return [Convert]::ToBase64String($bytes)
}

function Get-WindowsArchitecture {
    # Windows PowerShell 5.1 runs on .NET Framework, where
    # RuntimeInformation.OSArchitecture is not consistently available. These
    # variables report the native OS architecture even from a 32-bit process.
    $value = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }
    if (-not $value) { throw "Windows did not report a processor architecture" }
    switch ($value.ToUpperInvariant()) {
        "AMD64" { return "x64" }
        "X86_64" { return "x64" }
        "ARM64" { return "arm64" }
        default { throw "Unsupported Windows architecture: $value" }
    }
}

function Install-OfficialOpenCode {
    $architecture = Get-WindowsArchitecture
    $target = "windows-$architecture"
    if ($architecture -eq "x64") {
        try {
            Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(int ProcessorFeature);' -Name Kernel32 -Namespace Win32 -ErrorAction SilentlyContinue | Out-Null
            if (-not [Win32.Kernel32]::IsProcessorFeaturePresent(40)) { $target += "-baseline" }
        } catch { $target += "-baseline" }
    }

    [Console]::WriteLine("OpenCode was not found; locating the latest official V2 Windows build...")
    $latest = Invoke-RestMethod -Uri "https://opencode.ai/update/api/latest/cli/npm" -TimeoutSec 30
    $version = [string]$latest.version
    $basePackage = [string]$latest.metadata.package
    if (-not $version -or -not $basePackage) { throw "OpenCode update feed returned invalid metadata" }
    $scope = $basePackage -replace '/cli$', ''
    $packageName = "$scope/cli-$target"
    $encodedName = [Uri]::EscapeDataString($packageName).Replace('%2F', '%2f')
    $package = Invoke-RestMethod -Uri "https://registry.npmjs.org/$encodedName/$version" -TimeoutSec 30
    $tarball = [string]$package.dist.tarball
    $integrity = [string]$package.dist.integrity
    if (-not $tarball -or -not $integrity.StartsWith("sha512-")) { throw "OpenCode package did not provide SHA-512 integrity metadata" }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("opencode-smart-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    try {
        $archive = Join-Path $temp "opencode.tgz"
        Invoke-WebRequest -Uri $tarball -UseBasicParsing -OutFile $archive
        $actual = Convert-HexToBase64 (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash
        $expected = $integrity.Substring("sha512-".Length)
        if ($actual -ne $expected) { throw "OpenCode package integrity verification failed" }
        $tar = Get-Command tar.exe -ErrorAction Stop
        & $tar.Source -xzf $archive -C $temp
        if ($LASTEXITCODE -ne 0) { throw "tar.exe could not extract the OpenCode package" }
        $sourceBinary = Join-Path $temp "package\bin\opencode.exe"
        if (-not (Test-Path -LiteralPath $sourceBinary)) { throw "OpenCode package did not contain opencode.exe" }
        New-Item -ItemType Directory -Force -Path $ManagedOpenCodeDir | Out-Null
        Copy-Item -LiteralPath $sourceBinary -Destination (Join-Path $ManagedOpenCodeDir "opencode.exe") -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    }
}

$RealBinary = Find-ExistingOpenCode
if (-not $RealBinary) {
    Install-OfficialOpenCode
    $RealBinary = Join-Path $ManagedOpenCodeDir "opencode.exe"
}

$versionOutput = (& $RealBinary --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $versionOutput) { throw "Detected OpenCode executable did not run: $RealBinary" }

New-Item -ItemType Directory -Force -Path $BinDir, $ConfigDir | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceDir "opencode-smart.ps1") -Destination (Join-Path $BinDir "opencode-smart.ps1") -Force
Copy-Item -LiteralPath (Join-Path $SourceDir "opencode.cmd") -Destination (Join-Path $BinDir "opencode.cmd") -Force
Copy-Item -LiteralPath (Join-Path $SourceDir "opencode-free.cmd") -Destination (Join-Path $BinDir "opencode-free.cmd") -Force
Copy-Item -LiteralPath (Join-Path $SourceDir "opencode") -Destination (Join-Path $BinDir "opencode") -Force
Copy-Item -LiteralPath (Join-Path $SourceDir "opencode-free") -Destination (Join-Path $BinDir "opencode-free") -Force

$gitBashPresent = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files\Git\usr\bin\bash.exe",
    (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($gitBashPresent) {
    New-Item -ItemType Directory -Force -Path $GitBashBinDir | Out-Null
    foreach ($name in @("opencode", "opencode-free")) {
        $gitBashShim = Join-Path $GitBashBinDir $name
        if ((Test-Path -LiteralPath $gitBashShim) -and -not (Test-ManagedGitBashShim $gitBashShim)) {
            Write-Warning "$gitBashShim already exists and is not managed by this installer; leaving it unchanged"
            continue
        }
        Copy-Item -LiteralPath (Join-Path $SourceDir $name) -Destination $gitBashShim -Force
    }
}

@{ schema = 1; real_binary = $RealBinary } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$entries = @($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $BinDir.TrimEnd('\') })
Set-UserPath (@($BinDir) + $entries)
$env:Path = "$BinDir;$env:Path"

Write-Output "OpenCode Smart Free Launcher installed."
Write-Output "Real OpenCode: $RealBinary ($versionOutput)"
Write-Output "Wrapper: $(Join-Path $BinDir 'opencode.cmd')"
Write-Output "Open a new terminal, then run: opencode-free --smart-free-status"
