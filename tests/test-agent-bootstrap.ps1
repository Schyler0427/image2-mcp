$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

function Assert-Contains([string]$Path, [string]$Expected, [string]$Message) {
  Assert-True ([IO.File]::ReadAllText($Path).Contains($Expected)) $Message
}

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Helper = Join-Path $Root "scripts\bootstrap-agent-install.ps1"
Assert-True (Test-Path $Helper) "PowerShell Agent bootstrap helper is missing"

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("image2-bootstrap-test-" + [Guid]::NewGuid().ToString("N"))
$Harness = Join-Path $TempRoot "invoke-bootstrap.ps1"
$ReleaseJson = Join-Path $TempRoot "release.json"
$SecretText = "fixture-key-redacted"
$SavedEnvironment = @{}
foreach ($Name in @(
  "HOME", "USERPROFILE", "LOCALAPPDATA", "BOOTSTRAP_FIXTURE_HELPER",
  "BOOTSTRAP_FIXTURE_RELEASE_JSON", "BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE"
)) {
  $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
}

function New-SourceZip([string]$Name, [string]$Version, [string]$Mode = "ok") {
  $SourceParent = Join-Path $TempRoot ("source-" + $Name)
  $Tree = Join-Path $SourceParent "image2-mcp-0.2.1"
  $Archive = Join-Path $TempRoot ($Name + ".zip")
  New-Item -ItemType Directory -Force -Path (Join-Path $Tree "scripts") | Out-Null
  [IO.File]::WriteAllText((Join-Path $Tree "go.mod"), "module fixture`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $Tree "version.txt"), ($Version + "`n"), (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $Tree "install.sh"), "placeholder`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $Tree "scripts\run-image2-mcp.ps1"), "placeholder`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $Tree "install.ps1"), @'
param([switch]$KeyOnly)
$ErrorActionPreference = "Stop"
if (-not $KeyOnly) { exit 64 }
$FixtureKey = [Console]::In.ReadLine()
if ([string]::IsNullOrWhiteSpace($FixtureKey)) { exit 65 }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot ".env.local"), "OPENAI_IMAGE_BASE_URL=https://api.schyler.top`nOPENAI_IMAGE_API_KEY=stored`n", (New-Object Text.UTF8Encoding($false)))
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot "dist"), (Join-Path $HOME ".codex") | Out-Null
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "dist\image2-mcp.exe"), "fixture binary`n", (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $HOME ".codex\config.toml"), "[mcp_servers.image2]`ncommand = `"fixture`"`n", (New-Object Text.UTF8Encoding($false)))
if (Test-Path (Join-Path $PSScriptRoot ".fixture-install-fail")) { exit 41 }
Write-Host "Verification: OK"
'@, (New-Object Text.UTF8Encoding($false)))

  switch ($Mode) {
    "collision" {
      New-Item -ItemType Directory -Force -Path (Join-Path $Tree "customer-prefix"), (Join-Path $Tree "collision") | Out-Null
      [IO.File]::WriteAllText((Join-Path $Tree "customer-prefix\child.txt"), "new prefix content`n", (New-Object Text.UTF8Encoding($false)))
      [IO.File]::WriteAllText((Join-Path $Tree "collision\ignored.txt"), "new tracked content`n", (New-Object Text.UTF8Encoding($false)))
      [IO.File]::WriteAllText((Join-Path $Tree "casepath.txt"), "new case content`n", (New-Object Text.UTF8Encoding($false)))
    }
    "fail" {
      [IO.File]::WriteAllText((Join-Path $Tree ".fixture-install-fail"), "", (New-Object Text.UTF8Encoding($false)))
    }
    "invalid" {
      Remove-Item -Force (Join-Path $Tree "go.mod")
    }
  }
  Compress-Archive -Path $Tree -DestinationPath $Archive
  return $Archive
}

function New-UnsafeCaseZip {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = Join-Path $TempRoot "unsafe-case.zip"
  $Stream = [IO.File]::Open($Archive, [IO.FileMode]::Create)
  $Zip = New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($Name in @(
      "image2-mcp-0.2.1/install.sh",
      "image2-mcp-0.2.1/install.ps1",
      "image2-mcp-0.2.1/go.mod",
      "image2-mcp-0.2.1/Case.txt",
      "image2-mcp-0.2.1/case.txt"
    )) {
      $Entry = $Zip.CreateEntry($Name)
      $Writer = New-Object IO.StreamWriter($Entry.Open(), (New-Object Text.UTF8Encoding($false)))
      try { $Writer.Write("fixture") } finally { $Writer.Dispose() }
    }
  } finally {
    $Zip.Dispose()
    $Stream.Dispose()
  }
  return $Archive
}

function Set-TestHome([string]$HomePath) {
  [Environment]::SetEnvironmentVariable("HOME", $HomePath, "Process")
  [Environment]::SetEnvironmentVariable("USERPROFILE", $HomePath, "Process")
  [Environment]::SetEnvironmentVariable("LOCALAPPDATA", (Join-Path $HomePath "AppData\Local"), "Process")
}

function Invoke-TestBootstrap([string]$HomePath, [string]$Archive) {
  Set-TestHome $HomePath
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE", $Archive, "Process")
  $InputFile = Join-Path $TempRoot ("stdin-" + [Guid]::NewGuid().ToString("N"))
  try {
    [IO.File]::WriteAllText($InputFile, ($SecretText + "`r`nignored`r`n"), (New-Object Text.UTF8Encoding($false)))
    $PowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $Info = New-Object Diagnostics.ProcessStartInfo
    $Info.FileName = $env:ComSpec
    $Info.Arguments = '/d /s /c ""' + $PowerShell + '" -NoProfile -ExecutionPolicy Bypass -File "' + $Harness + '" < "' + $InputFile + '""'
    $Info.UseShellExecute = $false
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Info.CreateNoWindow = $true
    $Process = New-Object Diagnostics.Process
    $Process.StartInfo = $Info
    [void]$Process.Start()
    $Stdout = $Process.StandardOutput.ReadToEnd()
    $Stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()
    return [PSCustomObject]@{ ExitCode = $Process.ExitCode; Output = $Stdout + $Stderr }
  } finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $InputFile
  }
}

function Get-PreviousBackups([string]$Parent) {
  if (-not (Test-Path $Parent)) { return @() }
  return @(Get-ChildItem -LiteralPath $Parent -Directory -Filter "image2-mcp.backup.*" | ForEach-Object {
    $Previous = Join-Path $_.FullName "previous"
    if (Test-Path $Previous) { Get-Item -LiteralPath $Previous }
  })
}

try {
  New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
  [IO.File]::WriteAllText($ReleaseJson, @'
{
  "tag_name": "v0.2.1",
  "draft": false,
  "prerelease": false,
  "assets": [
    {"name":"image2-mcp_darwin_arm64.tar.gz"},
    {"name":"image2-mcp_darwin_amd64.tar.gz"},
    {"name":"image2-mcp_linux_arm64.tar.gz"},
    {"name":"image2-mcp_linux_amd64.tar.gz"},
    {"name":"image2-mcp_windows_arm64.zip"},
    {"name":"image2-mcp_windows_amd64.zip"}
  ]
}
'@, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($Harness, @'
$ErrorActionPreference = "Stop"
function Invoke-RestMethod {
  param([string]$Uri)
  return ([IO.File]::ReadAllText($env:BOOTSTRAP_FIXTURE_RELEASE_JSON) | ConvertFrom-Json)
}
function Invoke-WebRequest {
  param([string]$Uri, [string]$OutFile)
  Copy-Item -LiteralPath $env:BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE -Destination $OutFile
}
. $env:BOOTSTRAP_FIXTURE_HELPER
Invoke-AgentBootstrap
'@, (New-Object Text.UTF8Encoding($false)))
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_HELPER", $Helper, "Process")
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_RELEASE_JSON", $ReleaseJson, "Process")
  $HelperText = [IO.File]::ReadAllText($Helper)
  Assert-True (-not $HelperText.Contains("BOOTSTRAP_FIXTURE_")) "production helper contains test fixture override"

  $V1 = New-SourceZip "v1" "version-one"
  $V2 = New-SourceZip "v2" "version-two" "collision"
  $Fail = New-SourceZip "fail" "version-failing" "fail"
  $Invalid = New-SourceZip "invalid" "version-invalid" "invalid"
  $UnsafeCase = New-UnsafeCaseZip

  # First install and clean repeat.
  $CleanHome = Join-Path $TempRoot "clean-home"
  New-Item -ItemType Directory -Force -Path (Join-Path $CleanHome ".codex") | Out-Null
  [IO.File]::WriteAllText((Join-Path $CleanHome ".codex\config.toml"), "original config`n", (New-Object Text.UTF8Encoding($false)))
  $First = Invoke-TestBootstrap $CleanHome $V1
  Assert-True ($First.ExitCode -eq 0) "first install failed"
  Assert-True (-not $First.Output.Contains($SecretText)) "first install leaked key"
  $CleanTarget = Join-Path $CleanHome "AppData\Local\image2-mcp"
  Assert-Contains (Join-Path $CleanTarget "version.txt") "version-one" "first install source is wrong"
  Assert-Contains (Join-Path $CleanTarget ".image2-mcp-managed") "Schyler0427/image2-mcp" "managed marker is wrong"

  $CleanRepeat = Invoke-TestBootstrap $CleanHome $V2
  Assert-True ($CleanRepeat.ExitCode -eq 0) "clean repeat failed"
  Assert-Contains (Join-Path $CleanTarget "version.txt") "version-two" "clean repeat did not activate new source"
  $CleanBackups = @(Get-PreviousBackups (Split-Path -Parent $CleanTarget))
  Assert-True ($CleanBackups.Count -eq 1) "clean repeat did not retain exactly one backup"
  Assert-Contains (Join-Path $CleanBackups[0].FullName "version.txt") "version-one" "clean repeat backup is wrong"
  Assert-True ($CleanRepeat.Output.Contains("Previous installation retained at:")) "repeat omitted backup path"
  Assert-True ($CleanRepeat.Output.Contains("Previous local and customer content is not active in the refreshed target.")) "repeat omitted inactive-content warning"

  # Exact Git repeat preserves commits, dirty files, untracked/ignored data, junctions, empty dirs, case and prefix collisions.
  $GitHome = Join-Path $TempRoot "git-home"
  $GitTarget = Join-Path $GitHome "AppData\Local\image2-mcp"
  New-Item -ItemType Directory -Force -Path (Join-Path $GitTarget "scripts"), (Join-Path $GitHome ".codex") | Out-Null
  Copy-Item (Join-Path $Root "install.sh") (Join-Path $GitTarget "install.sh")
  Copy-Item (Join-Path $Root "install.ps1") (Join-Path $GitTarget "install.ps1")
  Copy-Item (Join-Path $Root "go.mod") (Join-Path $GitTarget "go.mod")
  [IO.File]::WriteAllText((Join-Path $GitTarget "tracked.txt"), "tracked base`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $GitTarget ".gitignore"), "collision/ignored.txt`n", (New-Object Text.UTF8Encoding($false)))
  & git -C $GitTarget init -q
  & git -C $GitTarget config user.email fixture@example.invalid
  & git -C $GitTarget config user.name fixture
  & git -C $GitTarget remote add origin https://github.com/Schyler0427/image2-mcp.git
  & git -C $GitTarget add .
  & git -C $GitTarget commit -qm base
  [IO.File]::WriteAllText((Join-Path $GitTarget "local-commit.txt"), "local commit`n", (New-Object Text.UTF8Encoding($false)))
  & git -C $GitTarget add local-commit.txt
  & git -C $GitTarget commit -qm local
  $OldGitHead = (& git -C $GitTarget rev-parse HEAD).Trim()
  [IO.File]::AppendAllText((Join-Path $GitTarget "tracked.txt"), "dirty tracked`n", (New-Object Text.UTF8Encoding($false)))
  New-Item -ItemType Directory -Force -Path (Join-Path $GitTarget "collision"), (Join-Path $GitTarget "ordinary"), (Join-Path $GitTarget "empty-dir") | Out-Null
  [IO.File]::WriteAllText((Join-Path $GitTarget "collision\ignored.txt"), "ignored customer content`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $GitTarget "ordinary\customer.txt"), "ordinary customer content`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $GitTarget "customer-prefix"), "prefix customer file`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $GitTarget "CasePath.txt"), "old case content`n", (New-Object Text.UTF8Encoding($false)))
  New-Item -ItemType Junction -Path (Join-Path $GitTarget "customer-link") -Target (Join-Path $GitTarget "ordinary") | Out-Null
  $GitRepeat = Invoke-TestBootstrap $GitHome $V2
  Assert-True ($GitRepeat.ExitCode -eq 0) "Git repeat failed"
  $GitBackups = @(Get-PreviousBackups (Split-Path -Parent $GitTarget))
  Assert-True ($GitBackups.Count -eq 1) "Git repeat did not retain backup"
  $GitBackup = $GitBackups[0].FullName
  Assert-True ((& git -C $GitBackup rev-parse HEAD).Trim() -eq $OldGitHead) "local commit was not retained"
  Assert-Contains (Join-Path $GitBackup "tracked.txt") "dirty tracked" "dirty tracked file was not retained"
  Assert-Contains (Join-Path $GitBackup "collision\ignored.txt") "ignored customer content" "ignored customer path was not retained"
  Assert-Contains (Join-Path $GitBackup "ordinary\customer.txt") "ordinary customer content" "ordinary customer path was not retained"
  Assert-True (Test-Path (Join-Path $GitBackup "empty-dir")) "empty customer directory was not retained"
  Assert-True (((Get-Item -Force (Join-Path $GitBackup "customer-link")).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) "customer junction was not retained"
  Assert-True (Test-Path (Join-Path $GitBackup "customer-prefix") -PathType Leaf) "prefix customer file was not retained"
  Assert-Contains (Join-Path $GitBackup "CasePath.txt") "old case content" "case-colliding customer file was not retained"
  Assert-Contains (Join-Path $GitTarget "collision\ignored.txt") "new tracked content" "new tracked collision path is wrong"
  Assert-True (Test-Path (Join-Path $GitTarget "customer-prefix\child.txt")) "new prefix path was not activated"
  Assert-Contains (Join-Path $GitTarget "casepath.txt") "new case content" "new case path was not activated"
  Assert-True ($GitRepeat.Output.Contains("not active in the refreshed target")) "Git repeat omitted inactive-content warning"
  Assert-True (-not $GitRepeat.Output.Contains($SecretText)) "Git repeat leaked key"

  # Ambiguous marker and target reparse point are untouched refusals.
  $AmbiguousHome = Join-Path $TempRoot "ambiguous-home"
  $AmbiguousTarget = Join-Path $AmbiguousHome "AppData\Local\image2-mcp"
  New-Item -ItemType Directory -Force -Path $AmbiguousTarget | Out-Null
  [IO.File]::WriteAllText((Join-Path $AmbiguousTarget ".image2-mcp-managed"), "wrong/repository", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $AmbiguousTarget "customer.txt"), "sentinel`n", (New-Object Text.UTF8Encoding($false)))
  $AmbiguousHash = (Get-FileHash (Join-Path $AmbiguousTarget "customer.txt") -Algorithm SHA256).Hash
  $Ambiguous = Invoke-TestBootstrap $AmbiguousHome $V2
  Assert-True ($Ambiguous.ExitCode -ne 0) "ambiguous target unexpectedly succeeded"
  Assert-True (((Get-FileHash (Join-Path $AmbiguousTarget "customer.txt") -Algorithm SHA256).Hash) -eq $AmbiguousHash) "ambiguous target changed"

  $LinkHome = Join-Path $TempRoot "target-link-home"
  $ExternalTarget = Join-Path $LinkHome "external-target"
  $LinkTarget = Join-Path $LinkHome "AppData\Local\image2-mcp"
  New-Item -ItemType Directory -Force -Path $ExternalTarget, (Split-Path -Parent $LinkTarget) | Out-Null
  [IO.File]::WriteAllText((Join-Path $ExternalTarget "customer.txt"), "external sentinel`n", (New-Object Text.UTF8Encoding($false)))
  New-Item -ItemType Junction -Path $LinkTarget -Target $ExternalTarget | Out-Null
  $LinkResult = Invoke-TestBootstrap $LinkHome $V2
  Assert-True ($LinkResult.ExitCode -ne 0) "target junction unexpectedly succeeded"
  Assert-True (((Get-Item -Force $LinkTarget).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) "target junction was replaced"
  Assert-Contains (Join-Path $ExternalTarget "customer.txt") "external sentinel" "target junction destination changed"

  # Invalid and case-ambiguous ZIPs fail before target mutation.
  $SourceHome = Join-Path $TempRoot "source-home"
  $SourceFirst = Invoke-TestBootstrap $SourceHome $V1
  Assert-True ($SourceFirst.ExitCode -eq 0) "source setup failed"
  $SourceTarget = Join-Path $SourceHome "AppData\Local\image2-mcp"
  [IO.File]::WriteAllText((Join-Path $SourceTarget "customer.txt"), "rollback sentinel`n", (New-Object Text.UTF8Encoding($false)))
  $Unsafe = Invoke-TestBootstrap $SourceHome $UnsafeCase
  Assert-True ($Unsafe.ExitCode -ne 0) "case-ambiguous ZIP unexpectedly succeeded"
  Assert-Contains (Join-Path $SourceTarget "customer.txt") "rollback sentinel" "unsafe ZIP changed target"
  $InvalidResult = Invoke-TestBootstrap $SourceHome $Invalid
  Assert-True ($InvalidResult.ExitCode -ne 0) "invalid source ZIP unexpectedly succeeded"
  Assert-Contains (Join-Path $SourceTarget "customer.txt") "rollback sentinel" "invalid ZIP changed target"

  # Installer failure restores complete target and prior Codex config.
  $RollbackHome = Join-Path $TempRoot "rollback-home"
  New-Item -ItemType Directory -Force -Path (Join-Path $RollbackHome ".codex") | Out-Null
  [IO.File]::WriteAllText((Join-Path $RollbackHome ".codex\config.toml"), "preinstall config`n", (New-Object Text.UTF8Encoding($false)))
  $RollbackFirst = Invoke-TestBootstrap $RollbackHome $V1
  Assert-True ($RollbackFirst.ExitCode -eq 0) "rollback setup failed"
  $RollbackTarget = Join-Path $RollbackHome "AppData\Local\image2-mcp"
  [IO.File]::WriteAllText((Join-Path $RollbackTarget "customer.txt"), "customer rollback content`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $RollbackHome ".codex\config.toml"), "prior config`n", (New-Object Text.UTF8Encoding($false)))
  $ConfigHash = (Get-FileHash (Join-Path $RollbackHome ".codex\config.toml") -Algorithm SHA256).Hash
  $Rollback = Invoke-TestBootstrap $RollbackHome $Fail
  Assert-True ($Rollback.ExitCode -ne 0) "failing installer unexpectedly succeeded"
  Assert-Contains (Join-Path $RollbackTarget "version.txt") "version-one" "installer failure did not restore source"
  Assert-Contains (Join-Path $RollbackTarget "customer.txt") "customer rollback content" "installer failure did not restore customer content"
  Assert-True (((Get-FileHash (Join-Path $RollbackHome ".codex\config.toml") -Algorithm SHA256).Hash) -eq $ConfigHash) "installer failure did not restore Codex config"
  Assert-True (@(Get-PreviousBackups (Split-Path -Parent $RollbackTarget)).Count -eq 0) "failed repeat left retained backup"
  Assert-True (-not $Rollback.Output.Contains($SecretText)) "installer failure leaked key"

  Write-Host "PASS: PowerShell Agent bootstrap helper"
} finally {
  foreach ($Name in $SavedEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($Name, $SavedEnvironment[$Name], "Process")
  }
  if (Test-Path $TempRoot) { Remove-Item -Recurse -Force $TempRoot }
}
