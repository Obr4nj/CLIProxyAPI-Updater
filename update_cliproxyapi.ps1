#requires -Version 5.1
<#
.SYNOPSIS
    Install or update CLIProxyAPI from GitHub releases.

.DESCRIPTION
    PowerShell port of:
    https://github.com/hexbee/CLIProxyAPI-mate/blob/master/update_cliproxyapi.sh

    Features:
      - Check latest/specific release
      - Dry-run
      - Force reinstall
      - Optional downgrade
      - Keep temporary files
      - Backup existing config.yaml
      - Verify installed version after update
      - GitHub token support

    GitHub token priority:
      1. -GitHubToken
      2. $env:GITHUB_TOKEN
      3. $env:GH_TOKEN

.EXAMPLE
    .\update_cliproxyapi.ps1

.EXAMPLE
    .\update_cliproxyapi.ps1 -CheckOnly

.EXAMPLE
    .\update_cliproxyapi.ps1 -DryRun

.EXAMPLE
    .\update_cliproxyapi.ps1 -TargetVersion v6.8.35

.EXAMPLE
    $env:GITHUB_TOKEN = "github_pat_xxx"
    .\update_cliproxyapi.ps1

.EXAMPLE
    .\update_cliproxyapi.ps1 -GitHubToken "github_pat_xxx"
#>

[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$AllowDowngrade,
    [switch]$KeepTemp,

    [string]$TargetVersion,
    [string]$GitHubToken,
    [string]$InstallDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$GitHubRepo = 'router-for-me/CLIProxyAPI'
$GitHubApiBase = "https://api.github.com/repos/$GitHubRepo"

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if (-not [string]::IsNullOrWhiteSpace($env:INSTALL_DIR)) {
        $InstallDir = $env:INSTALL_DIR
    }
    else {
        $InstallDir = Join-Path $PSScriptRoot 'CLIProxyAPI'
    }
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

$script:TempDir = $null
$script:EffectiveToken = $null
$script:Release = $null
$script:ReleaseTag = $null
$script:Version = $null
$script:PlatformName = $null
$script:Arch = $null
$script:ArchiveExt = $null
$script:BinaryName = $null
$script:PackageName = $null
$script:PlatformLabel = $null
$script:DownloadUrl = $null
$script:Asset = $null
$script:LocalVersion = $null

function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Fail {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host "Error: $Message" -ForegroundColor Red -ErrorAction Continue
    throw $Message
}

function Resolve-GitHubToken {
    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        return $GitHubToken.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        return $env:GITHUB_TOKEN.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        return $env:GH_TOKEN.Trim()
    }

    return $null
}

function Get-GitHubHeaders {
    param([switch]$Binary)

    $headers = @{
        'Accept' = if ($Binary) {
            'application/octet-stream'
        }
        else {
            'application/vnd.github+json'
        }
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'CLIProxyAPI-PowerShell-Updater'
    }

    if (-not [string]::IsNullOrWhiteSpace($script:EffectiveToken)) {
        $headers['Authorization'] = "Bearer $script:EffectiveToken"
    }

    return $headers
}

function Invoke-GitHubWebRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$OutFile,
        [switch]$Binary
    )

    $params = @{
        Uri         = $Uri
        Method      = 'Get'
        Headers     = (Get-GitHubHeaders -Binary:$Binary)
        ErrorAction = 'Stop'
    }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $params['UseBasicParsing'] = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $params['OutFile'] = $OutFile
    }

    try {
        return Invoke-WebRequest @params
    }
    catch {
        $details = $_.Exception.Message

        try {
            if ($null -ne $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
                $details = "HTTP $status - $details"
            }
        }
        catch {}

        Fail "GitHub request failed: $Uri`n$details"
    }
}

function Show-GitHubRateLimit {
    param($Response)

    if ($null -eq $Response) {
        return
    }

    try {
        $limit = $Response.Headers['X-RateLimit-Limit']
        $remaining = $Response.Headers['X-RateLimit-Remaining']
        $reset = $Response.Headers['X-RateLimit-Reset']

        if ($limit -is [System.Array]) { $limit = $limit[0] }
        if ($remaining -is [System.Array]) { $remaining = $remaining[0] }
        if ($reset -is [System.Array]) { $reset = $reset[0] }

        if ($limit -and $remaining -and $reset) {
            $resetDisplay = [string]$reset

            try {
                $resetDisplay = [DateTimeOffset]::FromUnixTimeSeconds([Int64]$reset).
                    ToLocalTime().
                    ToString('hh:mm:ss tt')
            }
            catch {}

            Write-Host "GitHub API: $remaining / $limit remaining | reset $resetDisplay"
        }
    }
    catch {
        # Informational only.
    }
}

function Normalize-Version {
    param([Parameter(Mandatory)][string]$Value)

    $result = $Value.Trim()

    if ($result.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $result = $result.Substring(1)
    }

    if ($result.EndsWith('-plus', [StringComparison]::OrdinalIgnoreCase)) {
        $result = $result.Substring(0, $result.Length - 5)
    }

    return $result
}

function Get-VersionParts {
    param([Parameter(Mandatory)][string]$Value)

    $normalized = Normalize-Version $Value
    $matches = [regex]::Matches($normalized, '\d+')

    $result = @()

    foreach ($match in $matches) {
        $result += [Int64]$match.Value
    }

    return @($result)
}

function Compare-Version {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $leftNormalized = Normalize-Version $Left
    $rightNormalized = Normalize-Version $Right

    if ($leftNormalized -eq $rightNormalized) {
        return 0
    }

    $leftParts = @(Get-VersionParts $leftNormalized)
    $rightParts = @(Get-VersionParts $rightNormalized)
    $max = [Math]::Max($leftParts.Count, $rightParts.Count)

    for ($i = 0; $i -lt $max; $i++) {
        $a = if ($i -lt $leftParts.Count) { $leftParts[$i] } else { 0 }
        $b = if ($i -lt $rightParts.Count) { $rightParts[$i] } else { 0 }

        if ($a -gt $b) { return 1 }
        if ($a -lt $b) { return -1 }
    }

    $cmp = [string]::Compare(
        $leftNormalized,
        $rightNormalized,
        [StringComparison]::OrdinalIgnoreCase
    )

    if ($cmp -gt 0) { return 1 }
    if ($cmp -lt 0) { return -1 }
    return 0
}

function Get-TargetRelease {
    if (-not [string]::IsNullOrWhiteSpace($TargetVersion)) {
        $requested = "v$(Normalize-Version $TargetVersion)"
        $uri = "$GitHubApiBase/releases/tags/$requested"
        Write-Info "Fetching release metadata for $requested from GitHub..."
    }
    else {
        $requested = $null
        $uri = "$GitHubApiBase/releases/latest"
        Write-Info 'Fetching latest release metadata from GitHub...'
    }

    $response = Invoke-GitHubWebRequest -Uri $uri
    Show-GitHubRateLimit -Response $response

    try {
        $release = $response.Content | ConvertFrom-Json
    }
    catch {
        Fail "failed to parse GitHub release JSON: $($_.Exception.Message)"
    }

    if ($null -eq $release -or [string]::IsNullOrWhiteSpace([string]$release.tag_name)) {
        Fail 'failed to parse tag_name from GitHub API response.'
    }

    $script:Release = $release
    $script:ReleaseTag = [string]$release.tag_name
    $script:Version = Normalize-Version $script:ReleaseTag

    if ($requested) {
        Write-Host "Target release: $script:ReleaseTag"
    }
    else {
        Write-Host "Latest release: $script:ReleaseTag"
    }

    Write-Host 'JSON parser: PowerShell ConvertFrom-Json'
    Write-Host "GitHub authentication: $(if ($script:EffectiveToken) { 'token enabled' } else { 'anonymous' })"
}

function Get-MappedArchitecture {
    $machine = $null

    try {
        $machine = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    catch {
        $machine = $env:PROCESSOR_ARCHITECTURE
    }

    switch -Regex ($machine) {
        '^(X64|AMD64|x86_64)$' {
            return 'amd64'
        }
        '^(Arm64|ARM64|aarch64)$' {
            return 'arm64'
        }
        default {
            Fail "unsupported architecture: $machine"
        }
    }
}

function Detect-Platform {
    $script:Arch = Get-MappedArchitecture

    $windows = $false
    $linux = $false
    $mac = $false

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $windows = $IsWindows
        $linux = $IsLinux
        $mac = $IsMacOS
    }
    else {
        $windows = ($env:OS -eq 'Windows_NT')
    }

    if ($windows) {
        $script:PlatformName = 'windows'
        $script:ArchiveExt = 'zip'
        $script:BinaryName = 'cli-proxy-api.exe'
    }
    elseif ($linux) {
        $script:PlatformName = 'linux'
        $script:ArchiveExt = 'tar.gz'
        $script:BinaryName = 'cli-proxy-api'
    }
    elseif ($mac) {
        $script:PlatformName = 'darwin'
        $script:ArchiveExt = 'tar.gz'
        $script:BinaryName = 'cli-proxy-api'
    }
    else {
        Fail 'unsupported platform.'
    }

    $script:PackageName = "CLIProxyAPI_$($script:Version)_$($script:PlatformName)_$($script:Arch).$($script:ArchiveExt)"
    $script:PlatformLabel = "$($script:PlatformName)/$($script:Arch)"
    $script:DownloadUrl = "https://github.com/$GitHubRepo/releases/download/$($script:ReleaseTag)/$($script:PackageName)"
}

function Validate-ReleaseAsset {
    $assets = @($script:Release.assets)

    foreach ($asset in $assets) {
        if ([string]$asset.name -eq $script:PackageName) {
            $script:Asset = $asset
            return
        }
    }

    Write-Host "Error: expected asset not found for this platform: $script:PackageName" -ForegroundColor Red
    Write-Host 'Available assets:'

    foreach ($asset in $assets) {
        if (-not [string]::IsNullOrWhiteSpace([string]$asset.name)) {
            Write-Host "  - $($asset.name)"
        }
    }

    throw "Release asset '$script:PackageName' not found."
}

function Detect-LocalVersion {
    $binaryPath = Join-Path $InstallDir $script:BinaryName
    $script:LocalVersion = $null

    if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
        Write-Host 'Local version: not installed'
        return
    }

    try {
        $helpOutput = & $binaryPath --help 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    catch {
        Fail "failed to execute '$binaryPath --help' to detect the local version. $($_.Exception.Message)"
    }

    if ($exitCode -ne 0) {
        Fail "failed to execute '$binaryPath --help' to detect the local version."
    }

    $match = [regex]::Match(
        $helpOutput,
        '(?m)^CLIProxyAPI Version:\s*([^,\s]+)'
    )

    if (-not $match.Success) {
        Fail "failed to parse the local version from '$binaryPath --help'."
    }

    $raw = $match.Groups[1].Value
    $script:LocalVersion = Normalize-Version $raw

    Write-Host "Local version: $raw"
}

function Show-PlannedActions {
    Write-Host 'Planned action summary:'
    Write-Host "  Platform: $script:PlatformLabel"
    Write-Host "  Install directory: $InstallDir"
    Write-Host "  Target release: $script:ReleaseTag"
    Write-Host "  Target package: $script:PackageName"
    Write-Host "  Download URL: $script:DownloadUrl"
    Write-Host '  JSON parser: PowerShell ConvertFrom-Json'
    Write-Host "  Keep temp files: $([int][bool]$KeepTemp)"
    Write-Host "  GitHub auth: $(if ($script:EffectiveToken) { 'token' } else { 'anonymous' })"

    if ([string]::IsNullOrWhiteSpace($script:LocalVersion)) {
        Write-Host '  Local status: not installed'
        Write-Host '  Decision: fresh install'
        return
    }

    Write-Host "  Local normalized version: $script:LocalVersion"

    $comparison = Compare-Version $script:LocalVersion $script:Version

    if ($comparison -eq 0) {
        if ($Force) {
            Write-Host '  Decision: reinstall same version due to -Force'
        }
        else {
            Write-Host '  Decision: already up to date, would exit'
        }

        return
    }

    if ($comparison -gt 0) {
        if ($AllowDowngrade) {
            Write-Host '  Decision: downgrade install allowed by -AllowDowngrade'
        }
        else {
            Write-Host '  Decision: downgrade detected, would exit'
        }

        return
    }

    Write-Host '  Decision: update to newer version'
}

function Download-ReleaseAsset {
    param([Parameter(Mandatory)][string]$Destination)

    if ($null -eq $script:Asset) {
        Fail 'release asset metadata is missing.'
    }

    # For authenticated downloads use the GitHub asset API URL.
    # For anonymous public downloads use browser_download_url.
    if (
        -not [string]::IsNullOrWhiteSpace($script:EffectiveToken) -and
        -not [string]::IsNullOrWhiteSpace([string]$script:Asset.url)
    ) {
        Invoke-GitHubWebRequest `
            -Uri ([string]$script:Asset.url) `
            -OutFile $Destination `
            -Binary | Out-Null
    }
    else {
        $url = [string]$script:Asset.browser_download_url

        if ([string]::IsNullOrWhiteSpace($url)) {
            $url = $script:DownloadUrl
        }

        Invoke-GitHubWebRequest `
            -Uri $url `
            -OutFile $Destination | Out-Null
    }
}

function Expand-ReleaseArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$ExtractDir
    )

    New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null

    if ($script:PlatformName -eq 'windows') {
        try {
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDir -Force
        }
        catch {
            Fail "failed to extract ZIP archive: $($_.Exception.Message)"
        }

        return
    }

    $tar = Get-Command tar -ErrorAction SilentlyContinue

    if ($null -eq $tar) {
        Fail "'tar' command not found."
    }

    & $tar.Source -xzf $ArchivePath -C $ExtractDir

    if ($LASTEXITCODE -ne 0) {
        Fail 'failed to extract tar.gz archive.'
    }
}

function Resolve-PackageRoot {
    param([Parameter(Mandatory)][string]$ExtractDir)

    $entries = @(Get-ChildItem -LiteralPath $ExtractDir -Force)

    if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
        return $entries[0].FullName
    }

    return $ExtractDir
}

function Backup-ExistingConfig {
    param([Parameter(Mandatory)][string]$TempDir)

    $configPath = Join-Path $InstallDir 'config.yaml'

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return $null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupName = "config.$timestamp.yaml"
    $tempBackup = Join-Path $TempDir $backupName

    Copy-Item -LiteralPath $configPath -Destination $tempBackup -Force
    Write-Info "Backed up existing config.yaml to $backupName."

    return $backupName
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $items = @(Get-ChildItem -LiteralPath $Source -Force)

    foreach ($item in $items) {
        Copy-Item `
            -LiteralPath $item.FullName `
            -Destination $Destination `
            -Recurse `
            -Force
    }
}

function Install-Release {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$TempDir,
        [string]$BackupName
    )

    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-DirectoryContents -Source $PackageRoot -Destination $InstallDir

    $exampleConfig = Join-Path $InstallDir 'config.example.yaml'
    $configPath = Join-Path $InstallDir 'config.yaml'

    if (-not (Test-Path -LiteralPath $exampleConfig -PathType Leaf)) {
        Fail 'config.example.yaml not found in the extracted package.'
    }

    if (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath -Force
    }

    Move-Item -LiteralPath $exampleConfig -Destination $configPath -Force

    if (-not [string]::IsNullOrWhiteSpace($BackupName)) {
        Copy-Item `
            -LiteralPath (Join-Path $TempDir $BackupName) `
            -Destination (Join-Path $InstallDir $BackupName) `
            -Force
    }

    $binary = Join-Path $InstallDir $script:BinaryName

    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        Fail "expected binary '$($script:BinaryName)' not found after installation."
    }

    if ($script:PlatformName -ne 'windows') {
        $chmod = Get-Command chmod -ErrorAction SilentlyContinue

        if ($null -ne $chmod) {
            & $chmod.Source +x $binary

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Unable to mark '$binary' executable."
            }
        }
    }
}

function Verify-InstalledVersion {
    Detect-LocalVersion

    if ([string]::IsNullOrWhiteSpace($script:LocalVersion)) {
        Fail 'failed to verify the installed version after installation.'
    }

    if ($script:LocalVersion -ne $script:Version) {
        Fail "installed version mismatch. Expected $script:Version, got $script:LocalVersion."
    }

    Write-Success "Verified installed version: $script:LocalVersion"
}

function Remove-TemporaryFiles {
    if ([string]::IsNullOrWhiteSpace($script:TempDir)) {
        return
    }

    if (-not (Test-Path -LiteralPath $script:TempDir)) {
        return
    }

    if ($KeepTemp) {
        Write-Info "Keeping temporary files at $script:TempDir"
        return
    }

    try {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force
    }
    catch {
        Write-Warning "Failed to remove temporary directory '$script:TempDir': $($_.Exception.Message)"
    }
}

function Main {
    $script:EffectiveToken = Resolve-GitHubToken

    $script:TempDir = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ("cliproxyapi-update-" + [guid]::NewGuid().ToString('N'))

    $extractDir = Join-Path $script:TempDir 'extracted'

    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    try {
        Get-TargetRelease
        Detect-Platform
        Detect-LocalVersion
        Validate-ReleaseAsset

        if ($CheckOnly) {
            Write-Success 'Check completed. No changes made.'
            return
        }

        if ($DryRun) {
            Show-PlannedActions
            Write-Success 'Dry run completed. No changes made.'
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($script:LocalVersion)) {
            $comparison = Compare-Version $script:LocalVersion $script:Version

            if ($comparison -eq 0 -and -not $Force) {
                Write-Success 'CLIProxyAPI is already up to date. Exiting.'
                return
            }

            if ($comparison -eq 0 -and $Force) {
                Write-Info 'Local version matches target version, continuing due to -Force.'
            }

            if ($comparison -gt 0) {
                if (-not $AllowDowngrade) {
                    Fail (
                        "local version ($script:LocalVersion) is newer than target " +
                        "version ($script:Version). Re-run with -AllowDowngrade to continue."
                    )
                }

                Write-Info 'Downgrade allowed by -AllowDowngrade.'
            }
        }

        $archivePath = Join-Path $script:TempDir "package.$($script:ArchiveExt)"

        Write-Info "Target platform: $script:PlatformLabel"
        Write-Info "Install directory: $InstallDir"
        Write-Info "Downloading $script:PackageName..."

        Download-ReleaseAsset -Destination $archivePath

        Write-Info 'Extracting package...'
        Expand-ReleaseArchive -ArchivePath $archivePath -ExtractDir $extractDir

        $packageRoot = Resolve-PackageRoot -ExtractDir $extractDir
        $backupName = Backup-ExistingConfig -TempDir $script:TempDir

        Write-Info 'Replacing installation directory...'
        Install-Release `
            -PackageRoot $packageRoot `
            -TempDir $script:TempDir `
            -BackupName $backupName

        Verify-InstalledVersion

        Write-Success "CLIProxyAPI $script:Version installed successfully."
        Write-Host "Binary: $(Join-Path $InstallDir $script:BinaryName)"
        Write-Host "Config: $(Join-Path $InstallDir 'config.yaml')"

        if (-not [string]::IsNullOrWhiteSpace($backupName)) {
            Write-Host "Backup: $(Join-Path $InstallDir $backupName)"
        }
    }
    finally {
        Remove-TemporaryFiles
    }
}

try {
    Main
}
catch {
    if ($_.Exception.Message -notmatch '^GitHub request failed:' -and
        $_.Exception.Message -notmatch '^Release asset ') {
        # Fail() has already emitted its own error message in most cases.
        # Avoid duplicating known messages while still returning non-zero.
    }

    exit 1
}
