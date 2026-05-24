param(
  [string]$AppDir,
  [string]$ProjectDir,
  [string]$Route = "/backups",
  [int]$RunSeconds = 45,
  [string]$CaptureOutDir,
  [string]$CaptureWindowSize = "1365x1100",
  [string]$RegularLogicalSize = "1365x900",
  [string]$FullLogicalSize = "1365x1800",
  [double]$CapturePixelRatio = 1.5,
  [switch]$Analyze,
  [switch]$Test,
  [switch]$BuildWindows,
  [switch]$RunWindows,
  [switch]$CapturePlaylist,
  [switch]$All,
  [switch]$KeepExistingApp
)

$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
  $scriptDir = Split-Path -Parent $PSCommandPath
  return (Resolve-Path -LiteralPath (Join-Path $scriptDir "..\..\..\..")).Path
}

function Add-LoopbackNoProxy {
  $loopback = @("localhost", "127.0.0.1", "::1")
  foreach ($name in @("NO_PROXY", "no_proxy")) {
    $current = [Environment]::GetEnvironmentVariable($name, "Process")
    $parts = @()
    if ($current) {
      $parts += $current.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($item in $loopback) {
      if ($parts -notcontains $item) {
        $parts += $item
      }
    }
    [Environment]::SetEnvironmentVariable($name, ($parts -join ","), "Process")
  }
}

function Invoke-Flutter {
  param(
    [Parameter(Mandatory = $true)][string[]]$Args,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory
  )
  Write-Host "`n> flutter $($Args -join ' ')" -ForegroundColor Cyan
  Push-Location -LiteralPath $WorkingDirectory
  try {
    & flutter @Args
    if ($LASTEXITCODE -ne 0) {
      throw "flutter $($Args -join ' ') failed with exit code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

function Stop-ProcessTree {
  param([Parameter(Mandatory = $true)][int]$ProcessId)
  $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ParentProcessId -eq $ProcessId }
  foreach ($child in $children) {
    Stop-ProcessTree -ProcessId $child.ProcessId
  }
  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Stop-ExistingProjectApp {
  param([Parameter(Mandatory = $true)][string]$WorkingDirectory)
  $buildRoot = (Join-Path $WorkingDirectory "build\windows").ToLowerInvariant()
  $processes = Get-Process -Name "fh-radio-studio" -ErrorAction SilentlyContinue
  foreach ($proc in $processes) {
    $path = $null
    try {
      $path = $proc.MainModule.FileName
    } catch {
      $path = $null
    }
    if (-not $path) {
      continue
    }
    if ($path.ToLowerInvariant().StartsWith($buildRoot)) {
      Write-Host "Stopping existing project app process: $($proc.Id) $path" -ForegroundColor Yellow
      Stop-ProcessTree -ProcessId $proc.Id
    }
  }
}

function Invoke-FlutterRunProbe {
  param(
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$Route,
    [Parameter(Mandatory = $true)][int]$RunSeconds
  )

  $stamp = [guid]::NewGuid().ToString("N")
  $stdout = Join-Path $env:TEMP "flutter_visual_qa_$stamp.out.log"
  $stderr = Join-Path $env:TEMP "flutter_visual_qa_$stamp.err.log"
  $args = @("run", "-d", "windows", "--route", $Route)

  Write-Host "`n> flutter $($args -join ' ')" -ForegroundColor Cyan
  $process = Start-Process `
    -FilePath "flutter" `
    -ArgumentList $args `
    -WorkingDirectory $WorkingDirectory `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru

  Start-Sleep -Seconds $RunSeconds
  $process.Refresh()
  $wasRunning = -not $process.HasExited
  if ($wasRunning) {
    Stop-ProcessTree -ProcessId $process.Id
  }

  $outText = if (Test-Path -LiteralPath $stdout) { Get-Content -Encoding UTF8 -LiteralPath $stdout -Raw } else { "" }
  $errText = if (Test-Path -LiteralPath $stderr) { Get-Content -Encoding UTF8 -LiteralPath $stderr -Raw } else { "" }
  $combined = "$outText`n$errText"

  Write-Host "run_probe_was_running=$wasRunning"
  Write-Host "stdout_log=$stdout"
  Write-Host "stderr_log=$stderr"
  Write-Host "--- flutter run stdout tail ---"
  (($outText -split "`r?`n") | Select-Object -Last 80) -join "`n" | Write-Host
  Write-Host "--- flutter run stderr tail ---"
  (($errText -split "`r?`n") | Select-Object -Last 80) -join "`n" | Write-Host

  $badPatterns = @(
    "Failed assertion",
    "Another exception was thrown",
    "RenderFlex overflowed",
    "semantics\.parentDataDirty",
    "Unhandled Exception"
  )
  foreach ($pattern in $badPatterns) {
    if ($combined -match $pattern) {
      throw "flutter run log matched failure pattern: $pattern"
    }
  }

  if (-not $wasRunning) {
    $exitCode = $process.ExitCode
    if ($null -eq $exitCode) {
      $exitCode = "<unknown>"
    }
    if ($exitCode -ne 0) {
      throw "flutter run exited early with code $exitCode"
    }
  }
}

function Invoke-PlaylistCapture {
  param(
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$WindowSize,
    [Parameter(Mandatory = $true)][string]$RegularSize,
    [Parameter(Mandatory = $true)][string]$FullSize,
    [Parameter(Mandatory = $true)][double]$PixelRatio
  )

  if (-not (Test-Path -LiteralPath $ProjectDir)) {
    throw "Playlist capture project directory does not exist: $ProjectDir"
  }

  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $regularOut = Join-Path $OutDir "playlist_regular.png"
  $fullOut = Join-Path $OutDir "playlist_full.png"

  $args = @(
    "run", "-d", "windows",
    "-t", "tool\playlist_capture_main.dart",
    "-a", "--window-size=$WindowSize",
    "-a", "--capture-regular-logical-size=$RegularSize",
    "-a", "--capture-full-logical-size=$FullSize",
    "-a", "--capture-regular-out=$regularOut",
    "-a", "--capture-full-out=$fullOut",
    "-a", "--capture-pixel-ratio=$PixelRatio",
    "-a", "--repo-root=$RepoRoot",
    "-a", "--project-dir=$ProjectDir"
  )

  Invoke-Flutter -Args $args -WorkingDirectory $WorkingDirectory
  Write-Host "playlist_regular_capture=$regularOut"
  Write-Host "playlist_full_capture=$fullOut"
}

$repoRoot = Resolve-RepoRoot
if (-not $AppDir) {
  $AppDir = Join-Path $repoRoot "app"
}
$AppDir = (Resolve-Path -LiteralPath $AppDir).Path
if (-not $ProjectDir) {
  $ProjectDir = Join-Path $repoRoot "test\project\cli-full-flow"
}
if (-not $CaptureOutDir) {
  $CaptureOutDir = Join-Path $AppDir "build\visual_qa"
}

if (-not ($Analyze -or $Test -or $BuildWindows -or $RunWindows -or $CapturePlaylist -or $All)) {
  $Analyze = $true
  $Test = $true
}
if ($All) {
  $Analyze = $true
  $Test = $true
  $BuildWindows = $true
  $RunWindows = $true
}

Add-LoopbackNoProxy
$env:TrackFileAccess = "false"

Write-Host "repo_root=$repoRoot"
Write-Host "app_dir=$AppDir"
Write-Host "route=$Route"
Write-Host "capture_out_dir=$CaptureOutDir"

if ($Analyze) {
  Invoke-Flutter -Args @("analyze") -WorkingDirectory $AppDir
}
if ($Test) {
  Invoke-Flutter -Args @("test") -WorkingDirectory $AppDir
}
if ($BuildWindows) {
  if (-not $KeepExistingApp) {
    Stop-ExistingProjectApp -WorkingDirectory $AppDir
  }
  Invoke-Flutter -Args @("build", "windows") -WorkingDirectory $AppDir
}
if ($RunWindows) {
  if (-not $KeepExistingApp) {
    Stop-ExistingProjectApp -WorkingDirectory $AppDir
  }
  Invoke-FlutterRunProbe -WorkingDirectory $AppDir -Route $Route -RunSeconds $RunSeconds
}
if ($CapturePlaylist) {
  if (-not $KeepExistingApp) {
    Stop-ExistingProjectApp -WorkingDirectory $AppDir
  }
  Invoke-PlaylistCapture `
    -WorkingDirectory $AppDir `
    -RepoRoot $repoRoot `
    -ProjectDir $ProjectDir `
    -OutDir $CaptureOutDir `
    -WindowSize $CaptureWindowSize `
    -RegularSize $RegularLogicalSize `
    -FullSize $FullLogicalSize `
    -PixelRatio $CapturePixelRatio
}

Write-Host "`nFlutter visual QA script completed successfully." -ForegroundColor Green
