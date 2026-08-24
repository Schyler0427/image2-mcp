$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

function Assert-Contains([string]$Path, [string]$Expected, [string]$Message) {
  Assert-True ([IO.File]::ReadAllText($Path).Contains($Expected)) $Message
}

function Assert-ZipContains([string]$ArchivePath, [string]$EntryName, [string]$Message) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Stream = [IO.File]::OpenRead($ArchivePath)
  $Zip = New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Read)
  try {
    $NormalizedEntryName = $EntryName.Replace('\', '/')
    $MatchingEntry = $Zip.Entries | Where-Object {
      $_.FullName.Replace('\', '/') -ceq $NormalizedEntryName
    } | Select-Object -First 1
    Assert-True ($null -ne $MatchingEntry) $Message
  } finally {
    $Zip.Dispose()
    $Stream.Dispose()
  }
}

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Helper = Join-Path $Root "scripts\bootstrap-agent-install.ps1"
Assert-True (Test-Path $Helper) "PowerShell Agent bootstrap helper is missing"

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("image2-bootstrap-test-" + [Guid]::NewGuid().ToString("N"))
$Harness = Join-Path $TempRoot "invoke-bootstrap.ps1"
$ReleaseJson = Join-Path $TempRoot "release.json"
$ReleasePage = Join-Path $TempRoot "release.html"
$ReleaseAssetsPage = Join-Path $TempRoot "release-assets.html"
$SecretText = "fixture-key-redacted"
$SavedEnvironment = @{}
foreach ($Name in @(
  "HOME", "USERPROFILE", "LOCALAPPDATA", "BOOTSTRAP_FIXTURE_HELPER",
  "BOOTSTRAP_FIXTURE_RELEASE_JSON", "BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE",
  "BOOTSTRAP_FIXTURE_RELEASE_PAGE", "BOOTSTRAP_FIXTURE_RELEASE_ASSETS_PAGE",
  "BOOTSTRAP_FIXTURE_RELEASE_PAGE_FAIL", "BOOTSTRAP_FIXTURE_NETWORK_LOG",
  "BOOTSTRAP_FIXTURE_FAIL_TXN_CLEANUP", "BOOTSTRAP_FIXTURE_BLOCK_GIT",
  "BOOTSTRAP_FIXTURE_GIT_TOPLEVEL", "BOOTSTRAP_FIXTURE_REAL_GIT",
  "BOOTSTRAP_FIXTURE_SOURCE_DOWNLOAD_MARKER", "IMAGE2_MCP_REPO", "PATH"
)) {
  $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
}

function New-SourceZip([string]$Name, [string]$Version, [string]$Mode = "ok") {
  $SourceParent = Join-Path $TempRoot ("source-" + $Name)
  $Tree = Join-Path $SourceParent "image2-mcp-0.2.3"
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
if ($env:IMAGE2_MCP_REPO -cne "Schyler0427/image2-mcp") { exit 66 }
Write-Host -NoNewline "OPENAI_IMAGE_API_KEY: "
$FixtureKey = [Console]::In.ReadLine()
Write-Host ""
if ([string]::IsNullOrWhiteSpace($FixtureKey)) { exit 65 }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot ".env.local"), "OPENAI_IMAGE_BASE_URL=https://api.schyler.top`nOPENAI_IMAGE_API_KEY=stored`n", (New-Object Text.UTF8Encoding($false)))
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot "dist"), (Join-Path $HOME ".codex") | Out-Null
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "dist\image2-mcp.exe"), "fixture binary`n", (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $HOME ".codex\config.toml"), "[mcp_servers.image2]`ncommand = `"fixture`"`n", (New-Object Text.UTF8Encoding($false)))
if (Test-Path (Join-Path $PSScriptRoot ".fixture-config-path-fail")) {
  $FixtureConfig = Join-Path $HOME ".codex\config.toml"
  Remove-Item -LiteralPath $FixtureConfig -Force
  New-Item -ItemType Directory -Path $FixtureConfig | Out-Null
  exit 42
}
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
    "config-path-fail" {
      [IO.File]::WriteAllText((Join-Path $Tree ".fixture-config-path-fail"), "", (New-Object Text.UTF8Encoding($false)))
    }
    "invalid" {
      Remove-Item -Force (Join-Path $Tree "go.mod")
    }
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($SourceParent, $Archive)
  return $Archive
}

function Add-TestZipEntry($Zip, [string]$Name, [int]$ExternalAttributes = 0) {
  $Entry = $Zip.CreateEntry($Name)
  $Entry.ExternalAttributes = $ExternalAttributes
  $Writer = New-Object IO.StreamWriter($Entry.Open(), (New-Object Text.UTF8Encoding($false)))
  try { $Writer.Write("fixture") } finally { $Writer.Dispose() }
}

function New-UnsafeCaseZip {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = Join-Path $TempRoot "unsafe-case.zip"
  $Stream = [IO.File]::Open($Archive, [IO.FileMode]::Create)
  $Zip = New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($Name in @(
      "image2-mcp-0.2.3/install.sh",
      "image2-mcp-0.2.3/install.ps1",
      "image2-mcp-0.2.3/go.mod",
      "image2-mcp-0.2.3/scripts/run-image2-mcp.ps1",
      "image2-mcp-0.2.3/Case.txt",
      "image2-mcp-0.2.3/case.txt"
    )) {
      Add-TestZipEntry $Zip $Name
    }
  } finally {
    $Zip.Dispose()
    $Stream.Dispose()
  }
  return $Archive
}

function New-UnsafePrefixZip([string]$Name, [switch]$ChildFirst) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = Join-Path $TempRoot ($Name + ".zip")
  $Stream = [IO.File]::Open($Archive, [IO.FileMode]::Create)
  $Zip = New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Create)
  $Required = @(
    "image2-mcp-0.2.3/install.sh",
    "image2-mcp-0.2.3/install.ps1",
    "image2-mcp-0.2.3/go.mod",
    "image2-mcp-0.2.3/scripts/run-image2-mcp.ps1"
  )
  $Collision = if ($ChildFirst) {
    @("image2-mcp-0.2.3/prefix/child.txt", "image2-mcp-0.2.3/prefix")
  } else {
    @("image2-mcp-0.2.3/prefix", "image2-mcp-0.2.3/prefix/child.txt")
  }
  try {
    foreach ($EntryName in @($Required + $Collision)) {
      Add-TestZipEntry $Zip $EntryName
    }
  } finally {
    $Zip.Dispose()
    $Stream.Dispose()
  }
  return $Archive
}

function New-UnsafeAttributeZip([string]$Name, [int]$ExternalAttributes) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = Join-Path $TempRoot ($Name + ".zip")
  $Stream = [IO.File]::Open($Archive, [IO.FileMode]::Create)
  $Zip = New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($EntryName in @(
      "image2-mcp-0.2.3/install.sh",
      "image2-mcp-0.2.3/install.ps1",
      "image2-mcp-0.2.3/go.mod",
      "image2-mcp-0.2.3/scripts/run-image2-mcp.ps1"
    )) {
      Add-TestZipEntry $Zip $EntryName
    }
    Add-TestZipEntry $Zip "image2-mcp-0.2.3/unsafe-link" $ExternalAttributes
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

function Invoke-TestBootstrap(
  [string]$HomePath,
  [string]$Archive,
  [switch]$WithoutHomeEnvironment,
  [switch]$FailTransactionCleanup,
  [string]$GitWrapperPath,
  [switch]$BlockGit,
  [string]$GitTopLevel,
  [string]$SourceDownloadMarker,
  [switch]$FailReleasePage,
  [string]$NetworkLog
) {
  Set-TestHome $HomePath
  if ($WithoutHomeEnvironment) {
    [Environment]::SetEnvironmentVariable("HOME", $null, "Process")
    Assert-True ($null -eq [Environment]::GetEnvironmentVariable("HOME", "Process")) "HOME fixture was not removed"
  }
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE", $Archive, "Process")
  [Environment]::SetEnvironmentVariable(
    "BOOTSTRAP_FIXTURE_FAIL_TXN_CLEANUP",
    $(if ($FailTransactionCleanup) { "1" } else { $null }),
    "Process"
  )
  [Environment]::SetEnvironmentVariable(
    "BOOTSTRAP_FIXTURE_BLOCK_GIT",
    $(if ($BlockGit) { "1" } else { $null }),
    "Process"
  )
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_GIT_TOPLEVEL", $GitTopLevel, "Process")
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_SOURCE_DOWNLOAD_MARKER", $SourceDownloadMarker, "Process")
  [Environment]::SetEnvironmentVariable(
    "BOOTSTRAP_FIXTURE_RELEASE_PAGE_FAIL",
    $(if ($FailReleasePage) { "1" } else { $null }),
    "Process"
  )
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_NETWORK_LOG", $NetworkLog, "Process")
  $OriginalPath = [Environment]::GetEnvironmentVariable("PATH", "Process")
  if ($GitWrapperPath) {
    [Environment]::SetEnvironmentVariable("PATH", ($GitWrapperPath + ";" + $OriginalPath), "Process")
  }
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
    [Environment]::SetEnvironmentVariable("PATH", $OriginalPath, "Process")
  }
}

function Get-PreviousBackups([string]$Parent) {
  if (-not (Test-Path $Parent)) { return @() }
  return @(Get-ChildItem -LiteralPath $Parent -Directory -Filter "image2-mcp.backup.*" | ForEach-Object {
    $Previous = Join-Path $_.FullName "previous"
    if (Test-Path $Previous) { Get-Item -LiteralPath $Previous }
  })
}

function New-GitOwnershipTarget([string]$Target) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Target "scripts") | Out-Null
  Copy-Item (Join-Path $Root "install.sh") (Join-Path $Target "install.sh")
  Copy-Item (Join-Path $Root "install.ps1") (Join-Path $Target "install.ps1")
  Copy-Item (Join-Path $Root "go.mod") (Join-Path $Target "go.mod")
  [IO.File]::WriteAllText((Join-Path $Target "customer.txt"), "ownership sentinel`n", (New-Object Text.UTF8Encoding($false)))
  & git -C $Target init -q
  & git -C $Target config user.email fixture@example.invalid
  & git -C $Target config user.name fixture
  & git -C $Target remote add origin https://github.com/Schyler0427/image2-mcp.git
  & git -C $Target add .
  & git -C $Target commit -qm ownership-fixture
}

function Assert-GitOwnershipRefusal(
  [string]$Name,
  [string]$HomePath,
  [string]$Archive,
  [string]$GitWrapperPath
) {
  $Target = Join-Path $HomePath "AppData\Local\image2-mcp"
  $SourceDownloadMarker = Join-Path $HomePath ".fixture-source-download"
  $SentinelHash = (Get-FileHash (Join-Path $Target "customer.txt") -Algorithm SHA256).Hash
  $Result = Invoke-TestBootstrap $HomePath $Archive -GitWrapperPath $GitWrapperPath -BlockGit -SourceDownloadMarker $SourceDownloadMarker
  Assert-True ($Result.ExitCode -ne 0) "$Name Git target unexpectedly succeeded"
  Assert-True ($Result.Output.Contains("existing Git target")) "$Name failed for the wrong reason: $($Result.Output)"
  Assert-True (-not (Test-Path $SourceDownloadMarker)) "$Name downloaded the source before refusing"
  Assert-True (((Get-FileHash (Join-Path $Target "customer.txt") -Algorithm SHA256).Hash) -eq $SentinelHash) "$Name changed the target"
  Assert-True (-not $Result.Output.Contains("OPENAI_IMAGE_API_KEY:")) "$Name reached key input"
}

try {
  New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
  [IO.File]::WriteAllText($ReleaseJson, @'
{
  "tag_name": "v0.2.3",
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
  [IO.File]::WriteAllText(
    $ReleasePage,
    ('<title>Release v0.2.3 ' + [char]0x00B7 + ' Schyler0427/image2-mcp ' + [char]0x00B7 + ' GitHub</title>'),
    (New-Object Text.UTF8Encoding($false))
  )
  [IO.File]::WriteAllText($ReleaseAssetsPage, (@(
    "image2-mcp_darwin_arm64.tar.gz",
    "image2-mcp_darwin_amd64.tar.gz",
    "image2-mcp_linux_arm64.tar.gz",
    "image2-mcp_linux_amd64.tar.gz",
    "image2-mcp_windows_arm64.zip",
    "image2-mcp_windows_amd64.zip"
  ) | ForEach-Object {
    "/Schyler0427/image2-mcp/releases/download/v0.2.3/$_"
  }) -join "`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($Harness, @'
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls
function Invoke-RestMethod {
  param([string]$Uri, [int]$TimeoutSec, [switch]$UseBasicParsing)
  if (-not [string]::IsNullOrEmpty($env:BOOTSTRAP_FIXTURE_NETWORK_LOG)) {
    [IO.File]::AppendAllText($env:BOOTSTRAP_FIXTURE_NETWORK_LOG, "REST|$TimeoutSec|$Uri`n", (New-Object Text.UTF8Encoding($false)))
  }
  if (-not $UseBasicParsing) {
    throw "fixture Release gate did not use basic parsing"
  }
  $Protocols = [Net.ServicePointManager]::SecurityProtocol
  if (($Protocols -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
    throw "fixture Release gate did not enable TLS 1.2"
  }
  if (($Protocols -band [Net.SecurityProtocolType]::Tls) -eq 0) {
    throw "fixture Release gate did not preserve TLS"
  }
  return ([IO.File]::ReadAllText($env:BOOTSTRAP_FIXTURE_RELEASE_JSON) | ConvertFrom-Json)
}
function Invoke-WebRequest {
  param([string]$Uri, [string]$OutFile, [int]$TimeoutSec, [switch]$UseBasicParsing)
  if (-not [string]::IsNullOrEmpty($env:BOOTSTRAP_FIXTURE_NETWORK_LOG)) {
    [IO.File]::AppendAllText($env:BOOTSTRAP_FIXTURE_NETWORK_LOG, "WEB|$TimeoutSec|$Uri`n", (New-Object Text.UTF8Encoding($false)))
  }
  if (-not $UseBasicParsing) {
    throw "fixture source download did not use basic parsing"
  }
  $Protocols = [Net.ServicePointManager]::SecurityProtocol
  if (($Protocols -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
    throw "fixture source download did not enable TLS 1.2"
  }
  if (($Protocols -band [Net.SecurityProtocolType]::Tls) -eq 0) {
    throw "fixture source download did not preserve TLS"
  }
  if ($Uri -eq "https://github.com/Schyler0427/image2-mcp/releases/tag/v0.2.3") {
    if ($env:BOOTSTRAP_FIXTURE_RELEASE_PAGE_FAIL -eq "1") {
      throw "fixture Release page failure"
    }
    return [PSCustomObject]@{ Content = [IO.File]::ReadAllText($env:BOOTSTRAP_FIXTURE_RELEASE_PAGE) }
  }
  if ($Uri -eq "https://github.com/Schyler0427/image2-mcp/releases/expanded_assets/v0.2.3") {
    return [PSCustomObject]@{ Content = [IO.File]::ReadAllText($env:BOOTSTRAP_FIXTURE_RELEASE_ASSETS_PAGE) }
  }
  if ($Uri -ne "https://github.com/Schyler0427/image2-mcp/archive/refs/tags/v0.2.3.zip") {
    throw "unexpected fixture URL: $Uri"
  }
  if (-not [string]::IsNullOrEmpty($env:BOOTSTRAP_FIXTURE_SOURCE_DOWNLOAD_MARKER)) {
    [IO.File]::WriteAllText($env:BOOTSTRAP_FIXTURE_SOURCE_DOWNLOAD_MARKER, "downloaded", (New-Object Text.UTF8Encoding($false)))
  }
  Copy-Item -LiteralPath $env:BOOTSTRAP_FIXTURE_SOURCE_ARCHIVE -Destination $OutFile
}
function Remove-Item {
  [CmdletBinding()]
  param(
    [string]$LiteralPath,
    [switch]$Recurse,
    [switch]$Force
  )
  if ($env:BOOTSTRAP_FIXTURE_FAIL_TXN_CLEANUP -eq "1" -and
      $LiteralPath -like "*.image2-mcp-bootstrap.*") {
    throw "fixture transaction cleanup failure"
  }
  Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
. $env:BOOTSTRAP_FIXTURE_HELPER
$PageRequiredAssets = @(
  "image2-mcp_darwin_arm64.tar.gz",
  "image2-mcp_darwin_amd64.tar.gz",
  "image2-mcp_linux_arm64.tar.gz",
  "image2-mcp_linux_amd64.tar.gz",
  "image2-mcp_windows_arm64.zip",
  "image2-mcp_windows_amd64.zip"
)
$PageFixture = '<title>Release v0.2.3 ' + [char]0x00B7 + ' Schyler0427/image2-mcp ' + [char]0x00B7 + ' GitHub</title>'
$AssetFixture = ($PageRequiredAssets | ForEach-Object {
  "/Schyler0427/image2-mcp/releases/download/v0.2.3/$_"
}) -join "`n"
Assert-AgentBootstrapReleasePage $PageFixture $AssetFixture $PageRequiredAssets
$OriginalRepository = [Environment]::GetEnvironmentVariable("IMAGE2_MCP_REPO", "Process")
try {
  Invoke-AgentBootstrap
} finally {
  if ([Environment]::GetEnvironmentVariable("IMAGE2_MCP_REPO", "Process") -cne $OriginalRepository) {
    throw "IMAGE2_MCP_REPO was not restored after installer invocation"
  }
}
'@, (New-Object Text.UTF8Encoding($false)))
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_HELPER", $Helper, "Process")
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_RELEASE_JSON", $ReleaseJson, "Process")
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_RELEASE_PAGE", $ReleasePage, "Process")
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_RELEASE_ASSETS_PAGE", $ReleaseAssetsPage, "Process")
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_REPO", "fixture-parent-repository", "Process")
  $HelperText = [IO.File]::ReadAllText($Helper)
  Assert-True (-not $HelperText.Contains("BOOTSTRAP_FIXTURE_")) "production helper contains test fixture override"

  $GitWrapperPath = Join-Path $TempRoot "git-wrapper"
  New-Item -ItemType Directory -Force -Path $GitWrapperPath | Out-Null
  $RealGit = (Get-Command git.exe -CommandType Application -ErrorAction Stop).Source
  [IO.File]::WriteAllText((Join-Path $GitWrapperPath "git.cmd"), @'
@echo off
if "%BOOTSTRAP_FIXTURE_BLOCK_GIT%"=="1" exit /b 97
if not "%BOOTSTRAP_FIXTURE_GIT_TOPLEVEL%"=="" (
  echo %BOOTSTRAP_FIXTURE_GIT_TOPLEVEL%
  exit /b 0
)
call "%BOOTSTRAP_FIXTURE_REAL_GIT%" %*
'@, (New-Object Text.UTF8Encoding($false)))
  [Environment]::SetEnvironmentVariable("BOOTSTRAP_FIXTURE_REAL_GIT", $RealGit, "Process")

  $V1 = New-SourceZip "v1" "version-one"
  $V2 = New-SourceZip "v2" "version-two" "collision"
  $Fail = New-SourceZip "fail" "version-failing" "fail"
  $ConfigPathFail = New-SourceZip "config-path-fail" "version-config-path-failing" "config-path-fail"
  $Invalid = New-SourceZip "invalid" "version-invalid" "invalid"
  $UnsafeCase = New-UnsafeCaseZip
  $UnsafePrefixFirst = New-UnsafePrefixZip "unsafe-prefix-first"
  $UnsafePrefixLast = New-UnsafePrefixZip "unsafe-prefix-last" -ChildFirst
  $UnsafeSymlink = New-UnsafeAttributeZip "unsafe-symlink" -1577123840
  $UnsafeReparse = New-UnsafeAttributeZip "unsafe-reparse" ([int][IO.FileAttributes]::ReparsePoint)
  Assert-ZipContains $Fail "image2-mcp-0.2.3/.fixture-install-fail" "failure fixture marker was omitted from ZIP"
  Assert-ZipContains $ConfigPathFail "image2-mcp-0.2.3/.fixture-config-path-fail" "config failure fixture marker was omitted from ZIP"

  # First install and clean repeat.
  $CleanHome = Join-Path $TempRoot "clean-home"
  $PageFirstNetwork = Join-Path $TempRoot "page-first-network.log"
  New-Item -ItemType Directory -Force -Path (Join-Path $CleanHome ".codex") | Out-Null
  [IO.File]::WriteAllText((Join-Path $CleanHome ".codex\config.toml"), "original config`n", (New-Object Text.UTF8Encoding($false)))
  $First = Invoke-TestBootstrap $CleanHome $V1 -NetworkLog $PageFirstNetwork
  Assert-True ($First.ExitCode -eq 0) "first install failed"
  Assert-True ($First.Output.Contains("Checking public Release...")) "Release progress marker missing"
  Assert-True ($First.Output.Contains("Downloading source package...")) "source progress marker missing"
  Assert-True ($First.Output.Contains("Preparing installation...")) "prepare progress marker missing"
  Assert-True ($First.Output.Contains("Installing platform binary...")) "install progress marker missing"
  Assert-True ($First.Output.Contains("Verifying local installation...")) "verification progress marker missing"
  $PageCalls = @([IO.File]::ReadAllLines($PageFirstNetwork))
  Assert-True ($PageCalls[0] -eq "WEB|15|https://github.com/Schyler0427/image2-mcp/releases/tag/v0.2.3") "Release page was not first"
  Assert-True ($PageCalls[1] -eq "WEB|15|https://github.com/Schyler0427/image2-mcp/releases/expanded_assets/v0.2.3") "assets page was not second"
  Assert-True ($PageCalls[2] -eq "WEB|60|https://github.com/Schyler0427/image2-mcp/archive/refs/tags/v0.2.3.zip") "source timeout is not bounded"
  Assert-True (-not ($PageCalls -match '^REST\|')) "API was called after page success"
  Assert-True ($First.Output.Contains("OPENAI_IMAGE_API_KEY:")) "bootstrap did not expose the key prompt"
  Assert-True (-not $First.Output.Contains($SecretText)) "first install leaked key"
  $CleanTarget = Join-Path $CleanHome "AppData\Local\image2-mcp"
  Assert-Contains (Join-Path $CleanTarget "version.txt") "version-one" "first install source is wrong"
  Assert-Contains (Join-Path $CleanTarget ".image2-mcp-managed") "Schyler0427/image2-mcp" "managed marker is wrong"

  $ApiFallbackHome = Join-Path $TempRoot "api-fallback-home"
  $ApiFallbackNetwork = Join-Path $TempRoot "api-fallback-network.log"
  $ApiFallback = Invoke-TestBootstrap $ApiFallbackHome $V1 -FailReleasePage -NetworkLog $ApiFallbackNetwork
  Assert-True ($ApiFallback.ExitCode -eq 0) "Release page failure did not recover through the API"
  $FallbackCalls = @([IO.File]::ReadAllLines($ApiFallbackNetwork))
  Assert-True ((@($FallbackCalls | Where-Object { $_ -like 'WEB|*|*/releases/tag/v0.2.3' })).Count -eq 1) "failed Release page was retried"
  Assert-True ((@($FallbackCalls | Where-Object { $_ -like 'REST|15|*api.github.com*' })).Count -eq 1) "API fallback was not called exactly once"
  Assert-True ((@($FallbackCalls | Where-Object { $_ -like '*expanded_assets*' })).Count -eq 0) "assets page was called after Release page failure"

  $CleanRepeat = Invoke-TestBootstrap $CleanHome $V2
  Assert-True ($CleanRepeat.ExitCode -eq 0) "clean repeat failed"
  Assert-Contains (Join-Path $CleanTarget "version.txt") "version-two" "clean repeat did not activate new source"
  $CleanBackups = @(Get-PreviousBackups (Split-Path -Parent $CleanTarget))
  Assert-True ($CleanBackups.Count -eq 1) "clean repeat did not retain exactly one backup"
  Assert-Contains (Join-Path $CleanBackups[0].FullName "version.txt") "version-one" "clean repeat backup is wrong"
  Assert-True ($CleanRepeat.Output.Contains("Previous installation retained at:")) "repeat omitted backup path"
  Assert-True ($CleanRepeat.Output.Contains("Previous local and customer content is not active in the refreshed target.")) "repeat omitted inactive-content warning"

  # A completed repeat with failed cleanup reports transaction and previous-target evidence.
  $CleanupHome = Join-Path $TempRoot "cleanup-failure-home"
  $CleanupFirst = Invoke-TestBootstrap $CleanupHome $V1
  Assert-True ($CleanupFirst.ExitCode -eq 0) "cleanup failure setup failed"
  $CleanupResult = Invoke-TestBootstrap $CleanupHome $V2 -FailTransactionCleanup
  Assert-True ($CleanupResult.ExitCode -ne 0) "transaction cleanup failure unexpectedly succeeded"
  Assert-True ($CleanupResult.Output.Contains("Transaction cleanup failed; evidence retained.")) "cleanup failure omitted diagnostic"
  Assert-True ($CleanupResult.Output.Contains("Retained transaction evidence:")) "cleanup failure omitted transaction path"
  Assert-True ($CleanupResult.Output.Contains("Previous installation retained at:")) "cleanup failure omitted previous installation path"
  Assert-True (-not $CleanupResult.Output.Contains($SecretText)) "cleanup failure leaked key"

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
  Assert-True (-not $GitRepeat.Output.Contains($SecretText)) "Git repeat leaked key"
  Assert-True ($GitRepeat.ExitCode -eq 0) "Git repeat failed: $($GitRepeat.Output)"
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

  # Git origin identity is byte-for-byte apart from PowerShell's removed record terminator.
  $WhitespaceGitHome = Join-Path $TempRoot "whitespace-git-home"
  $WhitespaceGitTarget = Join-Path $WhitespaceGitHome "AppData\Local\image2-mcp"
  New-Item -ItemType Directory -Force -Path (Join-Path $WhitespaceGitTarget "scripts") | Out-Null
  Copy-Item (Join-Path $Root "install.sh") (Join-Path $WhitespaceGitTarget "install.sh")
  Copy-Item (Join-Path $Root "install.ps1") (Join-Path $WhitespaceGitTarget "install.ps1")
  Copy-Item (Join-Path $Root "go.mod") (Join-Path $WhitespaceGitTarget "go.mod")
  [IO.File]::WriteAllText((Join-Path $WhitespaceGitTarget "customer.txt"), "whitespace sentinel`n", (New-Object Text.UTF8Encoding($false)))
  & git -C $WhitespaceGitTarget init -q
  & git -C $WhitespaceGitTarget remote add origin https://github.com/Schyler0427/image2-mcp.git
  & git -C $WhitespaceGitTarget config remote.origin.url "https://github.com/Schyler0427/image2-mcp.git "
  $WhitespaceOrigin = [string](& git -C $WhitespaceGitTarget remote get-url origin)
  Assert-True ($WhitespaceOrigin -ceq "https://github.com/Schyler0427/image2-mcp.git ") "Git fixture did not preserve origin whitespace"
  $WhitespaceHash = (Get-FileHash (Join-Path $WhitespaceGitTarget "customer.txt") -Algorithm SHA256).Hash
  $WhitespaceResult = Invoke-TestBootstrap $WhitespaceGitHome $V2
  Assert-True ($WhitespaceResult.ExitCode -ne 0) "whitespace Git origin unexpectedly succeeded"
  Assert-True ($WhitespaceResult.Output.Contains("origin does not match the fixed repository")) "whitespace Git origin failed for the wrong reason"
  Assert-True (((Get-FileHash (Join-Path $WhitespaceGitTarget "customer.txt") -Algorithm SHA256).Hash) -eq $WhitespaceHash) "whitespace Git target changed"

  # The no-Git parser refuses configuration that can redirect Git ownership
  # before downloading source, reading a key, or moving the target.
  $BareHome = Join-Path $TempRoot "git-bare-home"
  $BareTarget = Join-Path $BareHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $BareTarget
  [IO.File]::AppendAllText((Join-Path $BareTarget ".git\config"), "`n[core]`n`tbare = true`n", (New-Object Text.UTF8Encoding($false)))
  Assert-GitOwnershipRefusal "core.bare=true" $BareHome $V2 $GitWrapperPath

  $DuplicateBareHome = Join-Path $TempRoot "git-duplicate-bare-home"
  $DuplicateBareTarget = Join-Path $DuplicateBareHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $DuplicateBareTarget
  [IO.File]::AppendAllText((Join-Path $DuplicateBareTarget ".git\config"), "`n[core]`n`tbare = false`n`tbare = false`n", (New-Object Text.UTF8Encoding($false)))
  Assert-GitOwnershipRefusal "duplicate core.bare" $DuplicateBareHome $V2 $GitWrapperPath

  $WorktreeHome = Join-Path $TempRoot "git-worktree-home"
  $WorktreeTarget = Join-Path $WorktreeHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $WorktreeTarget
  [IO.File]::AppendAllText((Join-Path $WorktreeTarget ".git\config"), "`n[core]`n`tworktree = ../elsewhere`n", (New-Object Text.UTF8Encoding($false)))
  Assert-GitOwnershipRefusal "core.worktree" $WorktreeHome $V2 $GitWrapperPath

  $IncludeHome = Join-Path $TempRoot "git-include-home"
  $IncludeTarget = Join-Path $IncludeHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $IncludeTarget
  [IO.File]::AppendAllText((Join-Path $IncludeTarget ".git\config"), "`n[include]`n`tpath = ../untrusted.gitconfig`n", (New-Object Text.UTF8Encoding($false)))
  Assert-GitOwnershipRefusal "include section" $IncludeHome $V2 $GitWrapperPath

  $IncludeIfHome = Join-Path $TempRoot "git-include-if-home"
  $IncludeIfTarget = Join-Path $IncludeIfHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $IncludeIfTarget
  [IO.File]::AppendAllText((Join-Path $IncludeIfTarget ".git\config"), "`n[includeIf `"gitdir:../elsewhere/`"]`n`tpath = ../untrusted.gitconfig`n", (New-Object Text.UTF8Encoding($false)))
  Assert-GitOwnershipRefusal "includeIf section" $IncludeIfHome $V2 $GitWrapperPath

  $ConfigWorktreeHome = Join-Path $TempRoot "git-config-worktree-home"
  $ConfigWorktreeTarget = Join-Path $ConfigWorktreeHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $ConfigWorktreeTarget
  [IO.File]::WriteAllText((Join-Path $ConfigWorktreeTarget ".git\config.worktree"), "[core]`n`tworktree = ../elsewhere`n", (New-Object Text.UTF8Encoding($false)))
  Assert-GitOwnershipRefusal "config.worktree" $ConfigWorktreeHome $V2 $GitWrapperPath

  $DanglingConfigWorktreeHome = Join-Path $TempRoot "git-dangling-config-worktree-home"
  $DanglingConfigWorktreeTarget = Join-Path $DanglingConfigWorktreeHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $DanglingConfigWorktreeTarget
  $DanglingConfigWorktreeDestination = Join-Path $DanglingConfigWorktreeHome "missing-config-worktree"
  New-Item -ItemType Directory -Force -Path $DanglingConfigWorktreeDestination | Out-Null
  New-Item -ItemType Junction -Path (Join-Path $DanglingConfigWorktreeTarget ".git\config.worktree") -Target $DanglingConfigWorktreeDestination | Out-Null
  Remove-Item -LiteralPath $DanglingConfigWorktreeDestination -Recurse -Force
  Assert-GitOwnershipRefusal "dangling config.worktree" $DanglingConfigWorktreeHome $V2 $GitWrapperPath

  $WorktreeConfigHome = Join-Path $TempRoot "git-worktree-config-home"
  $WorktreeConfigTarget = Join-Path $WorktreeConfigHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $WorktreeConfigTarget
  [IO.File]::AppendAllText((Join-Path $WorktreeConfigTarget ".git\config"), "`n[extensions]`n`tworktreeConfig = true`n", (New-Object Text.UTF8Encoding($false)))
  Assert-GitOwnershipRefusal "extensions.worktreeConfig" $WorktreeConfigHome $V2 $GitWrapperPath

  $IncludeTrailingHome = Join-Path $TempRoot "git-include-trailing-home"
  $IncludeTrailingTarget = Join-Path $IncludeTrailingHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $IncludeTrailingTarget
  [IO.File]::AppendAllText((Join-Path $IncludeTrailingTarget ".git\config"), "`n[include] # trailing`n`tpath = ../untrusted.gitconfig`n", (New-Object Text.UTF8Encoding($false)))
  Assert-GitOwnershipRefusal "include section with trailing comment" $IncludeTrailingHome $V2 $GitWrapperPath

  # A usable Git executable must prove normalized top-level equality instead of
  # falling back to config-only proof when rev-parse points elsewhere.
  $TopLevelHome = Join-Path $TempRoot "git-toplevel-home"
  $TopLevelTarget = Join-Path $TopLevelHome "AppData\Local\image2-mcp"
  New-GitOwnershipTarget $TopLevelTarget
  $TopLevelMarker = Join-Path $TopLevelHome ".fixture-source-download"
  $TopLevelHash = (Get-FileHash (Join-Path $TopLevelTarget "customer.txt") -Algorithm SHA256).Hash
  $TopLevelResult = Invoke-TestBootstrap $TopLevelHome $V2 -GitWrapperPath $GitWrapperPath `
    -GitTopLevel (Join-Path $TempRoot "not-the-managed-target") -SourceDownloadMarker $TopLevelMarker
  Assert-True ($TopLevelResult.ExitCode -ne 0) "mismatched Git top-level unexpectedly succeeded"
  Assert-True ($TopLevelResult.Output.Contains("existing Git target")) "mismatched Git top-level failed for the wrong reason: $($TopLevelResult.Output)"
  Assert-True (-not (Test-Path $TopLevelMarker)) "mismatched Git top-level downloaded source before refusing"
  Assert-True (((Get-FileHash (Join-Path $TopLevelTarget "customer.txt") -Algorithm SHA256).Hash) -eq $TopLevelHash) "mismatched Git top-level changed the target"
  Assert-True (-not $TopLevelResult.Output.Contains("OPENAI_IMAGE_API_KEY:")) "mismatched Git top-level reached key input"

  # A dangling .git reparse point must not fall through to an otherwise-valid
  # archive marker. This initially succeeds because Test-Path misses it.
  $DanglingGitHome = Join-Path $TempRoot "dangling-git-home"
  $DanglingGitTarget = Join-Path $DanglingGitHome "AppData\Local\image2-mcp"
  New-Item -ItemType Directory -Force -Path (Join-Path $DanglingGitTarget "scripts") | Out-Null
  Copy-Item (Join-Path $Root "install.sh") (Join-Path $DanglingGitTarget "install.sh")
  Copy-Item (Join-Path $Root "install.ps1") (Join-Path $DanglingGitTarget "install.ps1")
  Copy-Item (Join-Path $Root "go.mod") (Join-Path $DanglingGitTarget "go.mod")
  [IO.File]::WriteAllText((Join-Path $DanglingGitTarget ".image2-mcp-managed"), "Schyler0427/image2-mcp", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $DanglingGitTarget "customer.txt"), "dangling Git sentinel`n", (New-Object Text.UTF8Encoding($false)))
  $DanglingGitDestination = Join-Path $DanglingGitHome "missing-git-directory"
  New-Item -ItemType Directory -Force -Path $DanglingGitDestination | Out-Null
  New-Item -ItemType Junction -Path (Join-Path $DanglingGitTarget ".git") -Target $DanglingGitDestination | Out-Null
  Remove-Item -LiteralPath $DanglingGitDestination -Recurse -Force
  $DanglingGitMarker = Join-Path $DanglingGitHome ".fixture-source-download"
  $DanglingGitHash = (Get-FileHash (Join-Path $DanglingGitTarget "customer.txt") -Algorithm SHA256).Hash
  $DanglingGitResult = Invoke-TestBootstrap $DanglingGitHome $V2 -GitWrapperPath $GitWrapperPath -BlockGit -SourceDownloadMarker $DanglingGitMarker
  Assert-True ($DanglingGitResult.ExitCode -ne 0) "dangling Git metadata unexpectedly fell through to archive-marker acceptance"
  Assert-True (-not (Test-Path $DanglingGitMarker)) "dangling Git metadata downloaded source before refusing"
  Assert-True (((Get-FileHash (Join-Path $DanglingGitTarget "customer.txt") -Algorithm SHA256).Hash) -eq $DanglingGitHash) "dangling Git metadata changed the target"
  Assert-True (-not $DanglingGitResult.Output.Contains("OPENAI_IMAGE_API_KEY:")) "dangling Git metadata reached key input"

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

  $BomHome = Join-Path $TempRoot "bom-marker-home"
  $BomTarget = Join-Path $BomHome "AppData\Local\image2-mcp"
  New-Item -ItemType Directory -Force -Path (Join-Path $BomTarget "scripts") | Out-Null
  Copy-Item (Join-Path $Root "install.sh") (Join-Path $BomTarget "install.sh")
  Copy-Item (Join-Path $Root "install.ps1") (Join-Path $BomTarget "install.ps1")
  Copy-Item (Join-Path $Root "go.mod") (Join-Path $BomTarget "go.mod")
  $BomEncoding = New-Object Text.UTF8Encoding($true)
  $BomMarkerBytes = [byte[]]($BomEncoding.GetPreamble() + $BomEncoding.GetBytes("Schyler0427/image2-mcp"))
  [IO.File]::WriteAllBytes((Join-Path $BomTarget ".image2-mcp-managed"), $BomMarkerBytes)
  [IO.File]::WriteAllText((Join-Path $BomTarget "customer.txt"), "BOM sentinel`n", (New-Object Text.UTF8Encoding($false)))
  Assert-True ($BomMarkerBytes[0] -eq 0xEF) "BOM marker fixture has no BOM"
  $BomHash = (Get-FileHash (Join-Path $BomTarget "customer.txt") -Algorithm SHA256).Hash
  $BomResult = Invoke-TestBootstrap $BomHome $V2
  Assert-True ($BomResult.ExitCode -ne 0) "BOM-prefixed marker unexpectedly succeeded"
  Assert-True ($BomResult.Output.Contains("marker does not match the fixed repository")) "BOM-prefixed marker failed for the wrong reason"
  Assert-True (((Get-FileHash (Join-Path $BomTarget "customer.txt") -Algorithm SHA256).Hash) -eq $BomHash) "BOM-prefixed marker target changed"

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

  # Invalid and structurally ambiguous ZIPs fail before target mutation.
  $SourceHome = Join-Path $TempRoot "source-home"
  $SourceFirst = Invoke-TestBootstrap $SourceHome $V1
  Assert-True ($SourceFirst.ExitCode -eq 0) "source setup failed"
  $SourceTarget = Join-Path $SourceHome "AppData\Local\image2-mcp"
  [IO.File]::WriteAllText((Join-Path $SourceTarget "customer.txt"), "rollback sentinel`n", (New-Object Text.UTF8Encoding($false)))
  $Unsafe = Invoke-TestBootstrap $SourceHome $UnsafeCase
  Assert-True ($Unsafe.ExitCode -ne 0) "case-ambiguous ZIP unexpectedly succeeded"
  Assert-True ($Unsafe.Output.Contains("case-insensitive duplicate canonical path")) "case-ambiguous ZIP failed for the wrong reason"
  Assert-Contains (Join-Path $SourceTarget "customer.txt") "rollback sentinel" "unsafe ZIP changed target"
  $UnsafePrefixFirstResult = Invoke-TestBootstrap $SourceHome $UnsafePrefixFirst
  Assert-True ($UnsafePrefixFirstResult.ExitCode -ne 0) "file-first prefix-collision ZIP unexpectedly succeeded"
  Assert-True ($UnsafePrefixFirstResult.Output.Contains("file/directory prefix collision")) "file-first prefix ZIP failed for the wrong reason"
  Assert-Contains (Join-Path $SourceTarget "customer.txt") "rollback sentinel" "file-first prefix ZIP changed target"
  $UnsafePrefixLastResult = Invoke-TestBootstrap $SourceHome $UnsafePrefixLast
  Assert-True ($UnsafePrefixLastResult.ExitCode -ne 0) "child-first prefix-collision ZIP unexpectedly succeeded"
  Assert-True ($UnsafePrefixLastResult.Output.Contains("file/directory prefix collision")) "child-first prefix ZIP failed for the wrong reason"
  Assert-Contains (Join-Path $SourceTarget "customer.txt") "rollback sentinel" "child-first prefix ZIP changed target"
  $UnsafeSymlinkResult = Invoke-TestBootstrap $SourceHome $UnsafeSymlink
  Assert-True ($UnsafeSymlinkResult.ExitCode -ne 0) "symlink ZIP unexpectedly succeeded"
  Assert-True ($UnsafeSymlinkResult.Output.Contains("symlink or reparse entry")) "symlink ZIP failed for the wrong reason"
  Assert-Contains (Join-Path $SourceTarget "customer.txt") "rollback sentinel" "symlink ZIP changed target"
  $UnsafeReparseResult = Invoke-TestBootstrap $SourceHome $UnsafeReparse
  Assert-True ($UnsafeReparseResult.ExitCode -ne 0) "reparse ZIP unexpectedly succeeded"
  Assert-True ($UnsafeReparseResult.Output.Contains("symlink or reparse entry")) "reparse ZIP failed for the wrong reason"
  Assert-Contains (Join-Path $SourceTarget "customer.txt") "rollback sentinel" "reparse ZIP changed target"
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

  # Incomplete config recovery retains transaction evidence instead of deleting it.
  $RecoveryHome = Join-Path $TempRoot "recovery-evidence-home"
  $RecoveryConfig = Join-Path $RecoveryHome ".codex\config.toml"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $RecoveryConfig) | Out-Null
  [IO.File]::WriteAllText($RecoveryConfig, "recovery setup config`n", (New-Object Text.UTF8Encoding($false)))
  $RecoveryFirst = Invoke-TestBootstrap $RecoveryHome $V1
  Assert-True ($RecoveryFirst.ExitCode -eq 0) "recovery evidence setup failed"
  $RecoveryTarget = Join-Path $RecoveryHome "AppData\Local\image2-mcp"
  [IO.File]::WriteAllText((Join-Path $RecoveryTarget "customer.txt"), "recovery customer content`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($RecoveryConfig, "recovery prior config`n", (New-Object Text.UTF8Encoding($false)))
  $Recovery = Invoke-TestBootstrap $RecoveryHome $ConfigPathFail
  Assert-True ($Recovery.ExitCode -ne 0) "config-path rollback failure unexpectedly succeeded"
  Assert-True ($Recovery.Output.Contains("rollback failed")) "config-path failure omitted rollback error"
  Assert-True (-not $Recovery.Output.Contains($SecretText)) "config-path rollback failure leaked key"
  Assert-Contains (Join-Path $RecoveryTarget "version.txt") "version-one" "config-path failure did not restore old target"
  Assert-Contains (Join-Path $RecoveryTarget "customer.txt") "recovery customer content" "config-path failure did not restore customer content"
  Assert-True (Test-Path $RecoveryConfig -PathType Container) "config-path failure did not retain blocking config directory"
  $RetainedTransactions = @(Get-ChildItem -LiteralPath (Split-Path -Parent $RecoveryTarget) -Directory -Force -Filter ".image2-mcp-bootstrap.*")
  Assert-True ($RetainedTransactions.Count -eq 1) "config-path failure did not retain exactly one transaction"
  $RetainedTransaction = $RetainedTransactions[0].FullName
  Assert-True ($Recovery.Output.Contains("Retained transaction evidence:")) "config-path failure omitted retained transaction report"
  Assert-True ($Recovery.Output.Contains("Retained failed target evidence:")) "config-path failure omitted failed-target path"
  Assert-True ($Recovery.Output.Contains($RetainedTransaction)) "config-path failure reported the wrong transaction path"
  Assert-True (Test-Path (Join-Path $RetainedTransaction "config.toml.before") -PathType Leaf) "config snapshot evidence was deleted"
  Assert-True (Test-Path (Join-Path $RetainedTransaction "failed-target") -PathType Container) "failed target evidence was deleted"
  Assert-Contains (Join-Path $RetainedTransaction "failed-target\version.txt") "version-config-path-failing" "failed target evidence is wrong"
  Assert-True (@(Get-PreviousBackups (Split-Path -Parent $RecoveryTarget)).Count -eq 0) "restored old target left a previous backup"

  # Standard Windows can omit HOME; bootstrap and child must share automatic $HOME.
  $AutomaticHome = Join-Path $TempRoot "automatic-home"
  $AutomaticConfig = Join-Path $AutomaticHome ".codex\config.toml"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $AutomaticConfig) | Out-Null
  [IO.File]::WriteAllText($AutomaticConfig, "automatic original config`n", (New-Object Text.UTF8Encoding($false)))
  $AutomaticFirst = Invoke-TestBootstrap $AutomaticHome $V1 -WithoutHomeEnvironment
  Assert-True ($AutomaticFirst.ExitCode -eq 0) "install without HOME environment failed"
  Assert-Contains $AutomaticConfig "[mcp_servers.image2]" "child did not use automatic HOME"
  $AutomaticTarget = Join-Path $AutomaticHome "AppData\Local\image2-mcp"
  [IO.File]::WriteAllText((Join-Path $AutomaticTarget "customer.txt"), "automatic rollback content`n", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($AutomaticConfig, "automatic prior config`n", (New-Object Text.UTF8Encoding($false)))
  $AutomaticConfigHash = (Get-FileHash $AutomaticConfig -Algorithm SHA256).Hash
  $AutomaticRollback = Invoke-TestBootstrap $AutomaticHome $Fail -WithoutHomeEnvironment
  Assert-True ($AutomaticRollback.ExitCode -ne 0) "failing install without HOME unexpectedly succeeded"
  Assert-Contains (Join-Path $AutomaticTarget "version.txt") "version-one" "HOME-less rollback did not restore source"
  Assert-Contains (Join-Path $AutomaticTarget "customer.txt") "automatic rollback content" "HOME-less rollback did not restore customer content"
  Assert-True (((Get-FileHash $AutomaticConfig -Algorithm SHA256).Hash) -eq $AutomaticConfigHash) "HOME-less rollback did not restore automatic HOME config"
  Assert-True (@(Get-PreviousBackups (Split-Path -Parent $AutomaticTarget)).Count -eq 0) "HOME-less failed repeat left retained backup"

  # Direct recovery state cases prove intent is reconciled against actual paths.
  . $Helper

  $DirectNoMoveRoot = Join-Path $TempRoot "direct-old-not-moved"
  $DirectNoMoveTransaction = Join-Path $DirectNoMoveRoot "transaction"
  $DirectNoMoveStage = Join-Path $DirectNoMoveTransaction "stage"
  $DirectNoMoveTarget = Join-Path $DirectNoMoveRoot "image2-mcp"
  $DirectNoMoveBackup = Join-Path $DirectNoMoveRoot "image2-mcp.backup.test"
  New-Item -ItemType Directory -Force -Path $DirectNoMoveStage, $DirectNoMoveTarget, $DirectNoMoveBackup | Out-Null
  [IO.File]::WriteAllText((Join-Path $DirectNoMoveTarget "identity.txt"), "old-not-moved", (New-Object Text.UTF8Encoding($false)))
  Restore-AgentBootstrapTransaction -Target $DirectNoMoveTarget -TransactionPath $DirectNoMoveTransaction `
    -StagePath $DirectNoMoveStage -BackupRoot $DirectNoMoveBackup -Repeat $true `
    -OldMoveIntent $true -NewMoveIntent $false -ConfigState $null
  Assert-Contains (Join-Path $DirectNoMoveTarget "identity.txt") "old-not-moved" "old-move failure treated old target as new"
  Assert-True (-not (Test-Path $DirectNoMoveBackup)) "old-move failure left empty backup root"
  Assert-True (-not (Test-Path (Join-Path $DirectNoMoveTransaction "failed-target"))) "old-move failure moved old target into failed evidence"

  $DirectOldMovedRoot = Join-Path $TempRoot "direct-old-moved"
  $DirectOldMovedTransaction = Join-Path $DirectOldMovedRoot "transaction"
  $DirectOldMovedStage = Join-Path $DirectOldMovedTransaction "stage"
  $DirectOldMovedTarget = Join-Path $DirectOldMovedRoot "image2-mcp"
  $DirectOldMovedBackup = Join-Path $DirectOldMovedRoot "image2-mcp.backup.test"
  New-Item -ItemType Directory -Force -Path $DirectOldMovedStage, (Join-Path $DirectOldMovedBackup "previous") | Out-Null
  [IO.File]::WriteAllText((Join-Path $DirectOldMovedBackup "previous\identity.txt"), "old-moved", (New-Object Text.UTF8Encoding($false)))
  Restore-AgentBootstrapTransaction -Target $DirectOldMovedTarget -TransactionPath $DirectOldMovedTransaction `
    -StagePath $DirectOldMovedStage -BackupRoot $DirectOldMovedBackup -Repeat $true `
    -OldMoveIntent $true -NewMoveIntent $false -ConfigState $null
  Assert-Contains (Join-Path $DirectOldMovedTarget "identity.txt") "old-moved" "old-moved state did not restore target"
  Assert-True (-not (Test-Path $DirectOldMovedBackup)) "old-moved state left backup root"

  $DirectBothMovedRoot = Join-Path $TempRoot "direct-both-moved"
  $DirectBothMovedTransaction = Join-Path $DirectBothMovedRoot "transaction"
  $DirectBothMovedStage = Join-Path $DirectBothMovedTransaction "stage"
  $DirectBothMovedTarget = Join-Path $DirectBothMovedRoot "image2-mcp"
  $DirectBothMovedBackup = Join-Path $DirectBothMovedRoot "image2-mcp.backup.test"
  New-Item -ItemType Directory -Force -Path $DirectBothMovedTransaction, $DirectBothMovedTarget, (Join-Path $DirectBothMovedBackup "previous") | Out-Null
  [IO.File]::WriteAllText((Join-Path $DirectBothMovedTarget "identity.txt"), "new-moved", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $DirectBothMovedBackup "previous\identity.txt"), "old-both-moved", (New-Object Text.UTF8Encoding($false)))
  Restore-AgentBootstrapTransaction -Target $DirectBothMovedTarget -TransactionPath $DirectBothMovedTransaction `
    -StagePath $DirectBothMovedStage -BackupRoot $DirectBothMovedBackup -Repeat $true `
    -OldMoveIntent $true -NewMoveIntent $true -ConfigState $null
  Assert-Contains (Join-Path $DirectBothMovedTarget "identity.txt") "old-both-moved" "both-moved state did not restore old target"
  Assert-Contains (Join-Path $DirectBothMovedTransaction "failed-target\identity.txt") "new-moved" "both-moved state did not retain failed target"
  Assert-True (-not (Test-Path $DirectBothMovedBackup)) "both-moved state left backup root"

  $DirectConfigRoot = Join-Path $TempRoot "direct-config-restore-failure"
  $DirectConfigTransaction = Join-Path $DirectConfigRoot "transaction"
  $DirectConfigStage = Join-Path $DirectConfigTransaction "stage"
  $DirectConfigTarget = Join-Path $DirectConfigRoot "image2-mcp"
  $DirectConfigBackup = Join-Path $DirectConfigRoot "image2-mcp.backup.test"
  $DirectConfigPath = Join-Path $DirectConfigRoot ".codex\config.toml"
  $DirectConfigSnapshot = Join-Path $DirectConfigTransaction "config.toml.before"
  New-Item -ItemType Directory -Force -Path $DirectConfigTransaction, $DirectConfigTarget, `
    (Join-Path $DirectConfigBackup "previous"), $DirectConfigPath | Out-Null
  [IO.File]::WriteAllText((Join-Path $DirectConfigTarget "identity.txt"), "new-config-failure", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $DirectConfigBackup "previous\identity.txt"), "old-config-failure", (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($DirectConfigSnapshot, "prior config", (New-Object Text.UTF8Encoding($false)))
  $DirectConfigState = [PSCustomObject]@{
    Path = $DirectConfigPath
    Existed = $true
    Snapshot = $DirectConfigSnapshot
    Attributes = [IO.FileAttributes]::Normal
    CreationTimeUtc = [DateTime]::UtcNow
    LastWriteTimeUtc = [DateTime]::UtcNow
  }
  $DirectConfigError = $null
  try {
    Restore-AgentBootstrapTransaction -Target $DirectConfigTarget -TransactionPath $DirectConfigTransaction `
      -StagePath $DirectConfigStage -BackupRoot $DirectConfigBackup -Repeat $true `
      -OldMoveIntent $true -NewMoveIntent $true -ConfigState $DirectConfigState
  } catch {
    $DirectConfigError = $_.Exception.Message
  }
  Assert-True ($DirectConfigError.Contains("could not restore Codex config")) "direct config failure did not report incomplete recovery"
  Assert-Contains (Join-Path $DirectConfigTarget "identity.txt") "old-config-failure" "direct config failure did not restore old target"
  Assert-Contains (Join-Path $DirectConfigTransaction "failed-target\identity.txt") "new-config-failure" "direct config failure deleted failed target evidence"
  Assert-True (Test-Path $DirectConfigSnapshot -PathType Leaf) "direct config failure deleted config snapshot evidence"
  Assert-True (-not (Test-Path $DirectConfigBackup)) "direct config failure left backup after target restoration"

  Write-Host "PASS: PowerShell Agent bootstrap helper"
} finally {
  foreach ($Name in $SavedEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($Name, $SavedEnvironment[$Name], "Process")
  }
  if (Test-Path $TempRoot) { Remove-Item -Recurse -Force $TempRoot }
}
