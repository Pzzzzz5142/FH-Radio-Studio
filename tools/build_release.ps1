#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Python = "3.12",
  [switch]$CleanBuild,
  [switch]$CleanDist,
  [switch]$SkipRuntimePrep,
  [switch]$SkipFlutterClean,
  [switch]$SkipArchive,
  [string]$ArchiveDir = "dist",
  [string]$ArchiveName
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$AppRoot = Join-Path $RepoRoot "app"
$BuildRoot = Join-Path $AppRoot "build\windows\x64"
$BundleDir = Join-Path $BuildRoot "runner\Release"

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Checked {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$WorkingDirectory = $RepoRoot
  )

  Write-Host "+ $FilePath $($Arguments -join ' ')"
  $previousLocation = (Get-Location).Path
  try {
    Set-Location -LiteralPath $WorkingDirectory
    $global:LASTEXITCODE = 0
    & $FilePath @Arguments
    $exitCode = $global:LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')"
    }
  } finally {
    Set-Location -LiteralPath $previousLocation
  }
}

function Add-LoopbackProxyBypass {
  $loopbackHosts = @("localhost", "127.0.0.1", "::1")
  foreach ($name in @("NO_PROXY", "no_proxy")) {
    $current = [Environment]::GetEnvironmentVariable($name, "Process")
    $parts = @()
    if ($current) {
      $parts += ($current -split "," | Where-Object { $_ })
    }
    foreach ($hostName in $loopbackHosts) {
      if ($parts -notcontains $hostName) {
        $parts += $hostName
      }
    }
    [Environment]::SetEnvironmentVariable($name, ($parts -join ","), "Process")
  }
}

function Get-AppReleaseId {
  $pubspecPath = Join-Path $AppRoot "pubspec.yaml"
  $pubspec = Get-Content -Encoding UTF8 -Raw -LiteralPath $pubspecPath
  if ($pubspec -match '(?m)^version:\s*[''"]?([^''"\s#]+)') {
    return $Matches[1]
  }
  throw "Could not read app release id from $pubspecPath"
}

function Test-ReleaseBranchName {
  param([string]$BranchName)
  $normalized = $BranchName.Trim()
  return $normalized -match '(?i)^release/v\d+\.\d+\.\d+(-rc\.\d+)?$'
}

function Get-BranchName {
  $explicit = [Environment]::GetEnvironmentVariable("FH_RADIO_STUDIO_BRANCH_NAME", "Process")
  if ($explicit -and $explicit.Trim()) {
    return $explicit.Trim()
  }

  $githubRefType = [Environment]::GetEnvironmentVariable("GITHUB_REF_TYPE", "Process")
  $githubRefName = [Environment]::GetEnvironmentVariable("GITHUB_REF_NAME", "Process")
  if ($githubRefType -eq "branch" -and $githubRefName -and $githubRefName.Trim()) {
    return $githubRefName.Trim()
  }

  $git = Get-Command "git" -ErrorAction SilentlyContinue
  if (-not $git) {
    return ""
  }

  $current = & $git.Source -C $RepoRoot branch --show-current 2>$null
  if ($LASTEXITCODE -eq 0) {
    $branch = ($current | Select-Object -First 1)
    if ($branch -and $branch.Trim()) {
      return $branch.Trim()
    }
  }

  $branches = & $git.Source -C $RepoRoot branch -r --contains HEAD 2>$null
  if ($LASTEXITCODE -eq 0) {
    foreach ($candidate in $branches) {
      $branch = $candidate.Trim().TrimStart("*").Trim()
      if ($branch.StartsWith("origin/", [System.StringComparison]::OrdinalIgnoreCase)) {
        $branch = $branch.Substring("origin/".Length)
      }
      if ($branch -and -not $branch.EndsWith("/HEAD") -and (Test-ReleaseBranchName -BranchName $branch)) {
        return $branch
      }
    }
  }

  return ""
}

function Get-CommitSha256 {
  $git = Get-Command "git" -ErrorAction SilentlyContinue
  if (-not $git) {
    return "None"
  }

  $output = & $git.Source -C $RepoRoot rev-parse --verify HEAD 2>$null
  if ($LASTEXITCODE -ne 0) {
    return "None"
  }

  $firstLine = $output | Select-Object -First 1
  if (-not $firstLine) {
    return "None"
  }

  $sha = $firstLine.Trim()
  if ($sha) {
    return $sha
  }
  return "None"
}

function Get-FlutterBuildInfoArguments {
  param(
    [string]$ReleaseId,
    [string]$CommitSha256,
    [string]$BranchName
  )

  return @(
    "--dart-define=FH_RADIO_STUDIO_RELEASE_ID=$ReleaseId",
    "--dart-define=FH_RADIO_STUDIO_COMMIT_SHA256=$CommitSha256",
    "--dart-define=FH_RADIO_STUDIO_BRANCH_NAME=$BranchName"
  )
}

function Resolve-RepoPath {
  param([string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return (Join-Path $RepoRoot $Path)
}

function Remove-RepoPath {
  param(
    [string]$Path,
    [string]$Description
  )

  $fullPath = [System.IO.Path]::GetFullPath((Resolve-RepoPath $Path))
  $repoPrefix = $RepoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove ${Description} outside repo: $fullPath"
  }

  if (Test-Path -LiteralPath $fullPath) {
    Write-Host "Removing ${Description}: $fullPath"
    Remove-Item -LiteralPath $fullPath -Recurse -Force
  }
}

function Assert-Exists {
  param(
    [string]$Path,
    [string]$Description
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing ${Description}: $Path"
  }
}

function Assert-CMakeGate {
  param([string]$Name)
  $cachePath = Join-Path $BuildRoot "CMakeCache.txt"
  Assert-Exists $cachePath "CMake cache"
  $cache = Get-Content -Encoding UTF8 -Raw -LiteralPath $cachePath
  $needle = "${Name}:BOOL=ON"
  if ($cache -notmatch [regex]::Escape($needle)) {
    throw "CMake release gate is not enabled: $needle"
  }
}

function Get-CMakeCacheValue {
  param([string]$Name)

  $cachePath = Join-Path $BuildRoot "CMakeCache.txt"
  if (-not (Test-Path -LiteralPath $cachePath)) {
    return $null
  }

  $pattern = "^" + [regex]::Escape($Name) + ":[^=]*=(.*)$"
  foreach ($line in Get-Content -Encoding UTF8 -LiteralPath $cachePath) {
    if ($line -match $pattern) {
      return $Matches[1]
    }
  }
  return $null
}

function Get-CMakeGeneratorArguments {
  $arguments = @()
  $generator = Get-CMakeCacheValue "CMAKE_GENERATOR"
  $platform = Get-CMakeCacheValue "CMAKE_GENERATOR_PLATFORM"
  $toolset = Get-CMakeCacheValue "CMAKE_GENERATOR_TOOLSET"

  if ($generator) {
    $arguments += @("-G", $generator)
  }
  if ($platform) {
    $arguments += @("-A", $platform)
  }
  if ($toolset) {
    $arguments += @("-T", $toolset)
  }

  return $arguments
}

function Get-CMakeCommand {
  $command = Get-CMakeCacheValue "CMAKE_COMMAND"
  if ($command -and (Test-Path -LiteralPath $command)) {
    return $command
  }
  return "cmake"
}

function Assert-ReleaseBundle {
  Write-Step "Validating release bundle"

  Assert-CMakeGate "FH_RADIO_STUDIO_REQUIRE_BUNDLED_UV"
  Assert-CMakeGate "FH_RADIO_STUDIO_REQUIRE_RELEASE_RUNTIME"
  Assert-CMakeGate "FH_RADIO_STUDIO_REQUIRE_RELEASE_TOOLCHAIN"
  Assert-CMakeGate "FH_RADIO_STUDIO_REQUIRE_RELEASE_AUDIO_TOOLS"

  Assert-Exists (Join-Path $BundleDir "fh-radio-studio.exe") "Windows executable"
  Assert-Exists (Join-Path $BundleDir "data\flutter_assets") "Flutter assets"
  Assert-Exists (Join-Path $BundleDir "runtime\pyproject.toml") "release runtime pyproject"
  Assert-Exists (Join-Path $BundleDir "runtime\uv.lock") "release runtime lockfile"
  Assert-Exists (Join-Path $BundleDir "toolchain\python") "bundled Python runtime"
  Assert-Exists (Join-Path $BundleDir "toolchain\uv\cache") "bundled uv cache"
  Assert-Exists (Join-Path $BundleDir "tools\uv\uv.exe") "bundled uv executable"
  Assert-Exists (Join-Path $BundleDir "toolchain\tools\audio\ffmpeg\ffmpeg.exe") "bundled ffmpeg"
  Assert-Exists (Join-Path $BundleDir "toolchain\tools\audio\vgmstream\vgmstream-cli.exe") "bundled vgmstream"
  Assert-Exists (Join-Path $BundleDir "toolchain\tools\audio\fmod\fsbankcl.exe") "bundled fsbankcl"
  Assert-Exists (Join-Path $BundleDir "toolchain\tools\ai\models\beat_this\torch_home\hub\checkpoints\beat_this-final0.ckpt") "bundled Beat This final0 checkpoint"
  $envsDir = Join-Path $BundleDir "toolchain\envs"
  if (Test-Path -LiteralPath $envsDir) {
    throw "Release bundle should not include prebuilt Python environments: $envsDir"
  }

  $wheelDir = Join-Path $BundleDir "runtime\wheels"
  $wheel = Get-ChildItem -LiteralPath $wheelDir -Filter "fh_radio_studio-*.whl" | Select-Object -First 1
  if (-not $wheel) {
    throw "Missing FH Radio Studio wheel in $wheelDir"
  }
}

function New-ReleaseArchive {
  param([string]$ReleaseId)

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $resolvedArchiveDir = Resolve-RepoPath $ArchiveDir
  New-Item -ItemType Directory -Force -Path $resolvedArchiveDir | Out-Null

  $name = $ArchiveName
  if (-not $name) {
    $name = "FHRadioStudio-$ReleaseId-windows-x64-$stamp.zip"
  }
  if (-not $name.EndsWith(".zip", [System.StringComparison]::OrdinalIgnoreCase)) {
    $name = "$name.zip"
  }

  $archivePath = Join-Path $resolvedArchiveDir $name
  if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
  }

  $tar = Get-Command "tar.exe" -ErrorAction SilentlyContinue
  if ($tar) {
    $bundleItems = Get-ChildItem -LiteralPath $BundleDir -Force | ForEach-Object { $_.Name }
    Invoke-Checked $tar.Source (@("-a", "-cf", $archivePath, "-C", $BundleDir) + $bundleItems)
  } else {
    $bundleItems = Get-ChildItem -LiteralPath $BundleDir -Force | ForEach-Object { $_.FullName }
    Compress-Archive -Path $bundleItems -DestinationPath $archivePath -CompressionLevel Optimal
  }

  if ($tar) {
    $firstEntry = & $tar.Source -tf $archivePath | Select-Object -First 1
    if ($LASTEXITCODE -ne 0) {
      throw "Release archive could not be listed: $archivePath"
    }
    if ($firstEntry -eq "./" -or $firstEntry.StartsWith("./", [System.StringComparison]::Ordinal)) {
      throw "Release archive contains Windows Explorer-incompatible './' entries"
    }
  }

  return $archivePath
}

Write-Host "FH Radio Studio Windows release packaging"
Write-Host "Repo: $RepoRoot"

Add-LoopbackProxyBypass
$env:TrackFileAccess = "false"
$ReleaseId = Get-AppReleaseId
$BranchName = Get-BranchName
$IsReleaseBranch = Test-ReleaseBranchName -BranchName $BranchName
$CommitSha256 = if ($IsReleaseBranch) { "None" } else { Get-CommitSha256 }
$FlutterBuildInfoArguments = Get-FlutterBuildInfoArguments `
  -ReleaseId $ReleaseId `
  -CommitSha256 $CommitSha256 `
  -BranchName $BranchName
Write-Host "Release id: $ReleaseId"
Write-Host "Branch: $(if ($BranchName) { $BranchName } else { 'unknown' })"
if (-not $IsReleaseBranch) {
  Write-Host "Commit sha256: $CommitSha256"
}

if ($CleanBuild) {
  Write-Step "Cleaning generated build state"
  Remove-RepoPath ".fh-radio-studio-dev\release-inputs" "release inputs"
  Remove-RepoPath "app\build" "Flutter build output"
  Remove-RepoPath "app\.dart_tool" "Flutter tool state"
  Remove-RepoPath "app\.flutter-plugins-dependencies" "Flutter plugin dependency cache"
  Remove-RepoPath "build" "Python build output"
  Remove-RepoPath "fh_radio_studio.egg-info" "Python package metadata"
}

if ($CleanDist) {
  Write-Step "Cleaning release archives"
  Remove-RepoPath $ArchiveDir "release archive directory"
}

if ((-not $SkipRuntimePrep) -or $CleanBuild) {
  Write-Step "Preparing release runtime inputs"
  Invoke-Checked "uv" @(
    "run",
    "python",
    "tools/prepare_release_runtime.py",
    "--clear",
    "--python",
    $Python
  )
}

Write-Step "Preparing Flutter project"
if ((-not $SkipFlutterClean) -or $CleanBuild) {
  Invoke-Checked "flutter" @("clean") $AppRoot
}
Invoke-Checked "flutter" @("pub", "get") $AppRoot

Write-Step "Configuring Windows release gates"
Invoke-Checked "flutter" (@("build", "windows", "--release", "--config-only") + $FlutterBuildInfoArguments) $AppRoot
$cmakeConfigureArgs = @()
$cmakeConfigureArgs += Get-CMakeGeneratorArguments
$cmakeConfigureArgs += @(
  "-S",
  "windows",
  "-B",
  "build/windows/x64",
  "-DFH_RADIO_STUDIO_REQUIRE_BUNDLED_UV=ON",
  "-DFH_RADIO_STUDIO_REQUIRE_RELEASE_RUNTIME=ON",
  "-DFH_RADIO_STUDIO_REQUIRE_RELEASE_TOOLCHAIN=ON",
  "-DFH_RADIO_STUDIO_REQUIRE_RELEASE_AUDIO_TOOLS=ON"
)
Invoke-Checked (Get-CMakeCommand) $cmakeConfigureArgs $AppRoot

Write-Step "Building Windows release"
Invoke-Checked "flutter" (@("build", "windows", "--release") + $FlutterBuildInfoArguments) $AppRoot

Assert-ReleaseBundle

if (-not $SkipArchive) {
  Write-Step "Creating release archive"
  $archivePath = New-ReleaseArchive -ReleaseId $ReleaseId
  Write-Host "Archive: $archivePath" -ForegroundColor Green
}

Write-Host ""
Write-Host "Release bundle: $BundleDir" -ForegroundColor Green
Write-Host "Done." -ForegroundColor Green
