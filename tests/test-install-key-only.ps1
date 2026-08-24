$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) {
    throw "FAIL: $Message"
  }
}

function Assert-InstallerParses {
  $Errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $script:Installer,
    [ref]$null,
    [ref]$Errors
  )
  Assert-True ($Errors.Count -eq 0) "install.ps1 has parser errors: $($Errors | Out-String)"
}

function Get-FileFingerprint([string]$Path) {
  if (Test-Path $Path) {
    return (Get-FileHash $Path -Algorithm SHA256).Hash
  }
  return "absent"
}

function Invoke-TestInstaller([string[]]$InstallerArgs, [string]$InputText = "") {
  $PowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $InputFile = Join-Path ([IO.Path]::GetTempPath()) ("image2-mcp-stdin-" + [Guid]::NewGuid().ToString("N"))
  try {
    [IO.File]::WriteAllText($InputFile, $InputText, (New-Object Text.UTF8Encoding($false)))
    $Info = New-Object System.Diagnostics.ProcessStartInfo
    $Info.FileName = $env:ComSpec
    $Info.Arguments = '/d /s /c ""' + $PowerShell + '" -NoProfile -ExecutionPolicy Bypass -File "' + `
      $script:Harness + '" ' + ($InstallerArgs -join ' ') + ' < "' + $InputFile + '""'
    $Info.UseShellExecute = $false
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Info.CreateNoWindow = $true
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $Info
    [void]$Process.Start()
    $Stdout = $Process.StandardOutput.ReadToEnd()
    $Stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()
    return [PSCustomObject]@{
      ExitCode = $Process.ExitCode
      Output = $Stdout + $Stderr
    }
  } finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $InputFile
  }
}

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("image2-mcp-test-" + [Guid]::NewGuid())
$TestHome = Join-Path $TempRoot "home"
$Repo = Join-Path $TempRoot "repo"
$Payload = Join-Path $TempRoot "payload"
$Fixture = Join-Path $TempRoot "image2-mcp.zip"
$script:Installer = Join-Path $Repo "install.ps1"
$script:Harness = Join-Path $TempRoot "invoke-installer.ps1"
$ConfigFile = Join-Path $TestHome ".codex\config.toml"
$EnvFile = Join-Path $Repo ".env.local"

$SavedEnvironment = @{}
foreach ($Name in @("HOME", "USERPROFILE", "LOCALAPPDATA", "IMAGE2_MCP_TEST_RELEASE_ZIP", "IMAGE2_MCP_TEST_INSTALLER", "IMAGE2_MCP_TEST_EXPECTED_BASE_URL", "IMAGE2_MCP_TEST_EXPECTED_API_KEY", "OPENAI_IMAGE_BASE_URL", "OPENAI_IMAGE_API_KEY")) {
  $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
}

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $TestHome ".codex"), (Join-Path $Repo "scripts"), $Payload | Out-Null
  Copy-Item (Join-Path $Root "install.ps1") $script:Installer
  Copy-Item (Join-Path $Root "scripts\run-image2-mcp.ps1") (Join-Path $Repo "scripts\run-image2-mcp.ps1")
  $RunnerSource = @'
using System;

public static class Program {
  public static int Main() {
    bool baseUrlMatches = String.Equals(
      Environment.GetEnvironmentVariable("OPENAI_IMAGE_BASE_URL"),
      Environment.GetEnvironmentVariable("IMAGE2_MCP_TEST_EXPECTED_BASE_URL"),
      StringComparison.Ordinal);
    bool apiKeyMatches = String.Equals(
      Environment.GetEnvironmentVariable("OPENAI_IMAGE_API_KEY"),
      Environment.GetEnvironmentVariable("IMAGE2_MCP_TEST_EXPECTED_API_KEY"),
      StringComparison.Ordinal);
    return baseUrlMatches && apiKeyMatches ? 0 : 29;
  }
}
'@
  Add-Type -TypeDefinition $RunnerSource -Language CSharp -OutputAssembly (Join-Path $Payload "image2-mcp.exe") -OutputType ConsoleApplication
  Compress-Archive -Path (Join-Path $Payload "image2-mcp.exe") -DestinationPath $Fixture
  [IO.File]::WriteAllText($script:Harness, @'
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls

function Invoke-WebRequest {
  param([string]$Uri, [string]$OutFile, [int]$TimeoutSec, [switch]$UseBasicParsing)
  if (-not $UseBasicParsing) {
    throw "fixture download did not use basic parsing"
  }
  if ($TimeoutSec -ne 90) {
    throw "fixture binary download timeout was $TimeoutSec instead of 90"
  }
  $Protocols = [Net.ServicePointManager]::SecurityProtocol
  if (($Protocols -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
    throw "fixture download did not enable TLS 1.2"
  }
  if (($Protocols -band [Net.SecurityProtocolType]::Tls) -eq 0) {
    throw "fixture download did not preserve TLS"
  }
  Copy-Item -LiteralPath $env:IMAGE2_MCP_TEST_RELEASE_ZIP -Destination $OutFile
}

. $env:IMAGE2_MCP_TEST_INSTALLER @args
Invoke-Installer
'@, (New-Object Text.UTF8Encoding($false)))
  Assert-InstallerParses
  $ProductionInstallerText = [IO.File]::ReadAllText((Join-Path $Root "install.ps1"))
  Assert-True (-not $ProductionInstallerText.Contains("IMAGE2_MCP_TEST_RELEASE_ZIP")) "production installer contains a local Release override"

  [Environment]::SetEnvironmentVariable("HOME", $TestHome, "Process")
  [Environment]::SetEnvironmentVariable("USERPROFILE", $TestHome, "Process")
  [Environment]::SetEnvironmentVariable("LOCALAPPDATA", (Join-Path $TestHome "AppData\Local"), "Process")
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_RELEASE_ZIP", $Fixture, "Process")
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_INSTALLER", $script:Installer, "Process")
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_EXPECTED_BASE_URL", "https://api.schyler.top", "Process")
  [Environment]::SetEnvironmentVariable("OPENAI_IMAGE_BASE_URL", "https://ignored.invalid", "Process")
  [Environment]::SetEnvironmentVariable("OPENAI_IMAGE_API_KEY", "old-key-must-be-ignored", "Process")

  $InitialConfig = @'
model = "gpt-5"

[mcp_servers.image2]
command = "C:\old\runner.ps1"

[mcp_servers.image2.env]
OLD = "value"

[mcp_servers.keep]
command = "C:\keep\runner.exe"

[mcp_servers.image20]
command = "C:\keep\image20-runner.exe"
'@
  [IO.File]::WriteAllText($ConfigFile, $InitialConfig, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $Repo ".env"), @'
OPENAI_IMAGE_BASE_URL="https://legacy.invalid"
OPENAI_IMAGE_API_KEY="legacy-key-must-not-win"
'@, (New-Object Text.UTF8Encoding($false)))

  $ConfigHash = (Get-FileHash $ConfigFile -Algorithm SHA256).Hash
  $Help = Invoke-TestInstaller -InstallerArgs @("-Help")
  Assert-True ($Help.ExitCode -eq 0) "-Help failed"
  Assert-True ($Help.Output.Contains("Usage:")) "-Help omitted usage"
  Assert-True (-not $Help.Output.Contains("Downloading prebuilt binary")) "-Help started installation"
  Assert-True (((Get-FileHash $ConfigFile -Algorithm SHA256).Hash) -eq $ConfigHash) "-Help changed Codex config"
  Assert-True (-not (Test-Path $EnvFile)) "-Help wrote .env.local"

  $KeyHelp = Invoke-TestInstaller -InstallerArgs @("-KeyOnly", "-Help")
  Assert-True ($KeyHelp.ExitCode -eq 0) "-KeyOnly -Help failed"
  Assert-True (-not $KeyHelp.Output.Contains("OPENAI_IMAGE_API_KEY:")) "-KeyOnly -Help prompted for a key"
  Assert-True (-not (Test-Path $EnvFile)) "-KeyOnly -Help wrote .env.local"

  $Secret = 'sk-test-do-not-print'
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_EXPECTED_API_KEY", $Secret, "Process")
  $Result = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText ($Secret + "`r`nignored-second-line`r`n")
  Assert-True ($Result.ExitCode -eq 0) "Key-only install failed: $($Result.Output)"
  Assert-True ($Result.Output.Contains("Verification: OK")) "verification marker missing"
  Assert-True (-not $Result.Output.Contains($Secret)) "API Key leaked to output"
  Assert-True ($Result.Output.Contains("image2-mcp_windows_")) "Release asset name was not reported"
  Assert-True ($Result.Output.Contains("https://github.com/Schyler0427/image2-mcp/releases/download/v0.2.2/")) "Release tag is not fixed"
  Assert-True ($Result.Output.Contains("Base URL: https://api.schyler.top")) "reported base URL is not fixed"
  Assert-True (-not $Result.Output.Contains("legacy-key-must-not-win")) "legacy API Key leaked to output"

  $Config = [IO.File]::ReadAllText($ConfigFile)
  Assert-True ($Config.Contains('model = "gpt-5"')) "top-level Codex config was removed"
  Assert-True ($Config.Contains('[mcp_servers.keep]')) "unrelated MCP config was removed"
  Assert-True ($Config.Contains('[mcp_servers.image20]')) "similarly named MCP config was removed"
  Assert-True ($Config.Contains('C:\keep\image20-runner.exe')) "similarly named MCP runner was removed"
  Assert-True (-not $Config.Contains('C:\old\runner.ps1')) "old Image2 root config remains"
  Assert-True (-not $Config.Contains('OLD = "value"')) "old Image2 descendant config remains"
  Assert-True (([regex]::Matches($Config, '(?m)^\[mcp_servers\.image2\]\r?$')).Count -eq 1) "Image2 root table count is not one"
  Assert-True ($Config.Contains('scripts\\run-image2-mcp.ps1')) "Codex config does not reference the runner"
  Assert-True (-not $Config.Contains("OPENAI_IMAGE_API_KEY")) "API Key setting leaked to Codex config"
  Assert-True ((Test-Path (Join-Path $Repo "dist\image2-mcp.exe"))) "Release binary is missing"

  $BadFixture = Join-Path $TempRoot "image2-mcp-extra.zip"
  $BadExtra = Join-Path $Payload "extra.txt"
  [IO.File]::WriteAllText($BadExtra, "unexpected entry", (New-Object Text.UTF8Encoding($false)))
  Compress-Archive -Path (Join-Path $Payload "image2-mcp.exe"), $BadExtra -DestinationPath $BadFixture
  $BinaryHashBefore = (Get-FileHash (Join-Path $Repo "dist\image2-mcp.exe") -Algorithm SHA256).Hash
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_RELEASE_ZIP", $BadFixture, "Process")
  $BadResult = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText ($Secret + "`r`n")
  Assert-True ($BadResult.ExitCode -ne 0) "multi-entry prebuilt ZIP unexpectedly succeeded"
  Assert-True ($BadResult.Output.Contains("prebuilt archive must contain exactly one image2-mcp.exe file")) "multi-entry prebuilt ZIP error is unclear"
  Assert-True (((Get-FileHash (Join-Path $Repo "dist\image2-mcp.exe") -Algorithm SHA256).Hash) -eq $BinaryHashBefore) "multi-entry prebuilt ZIP changed the binary"
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_RELEASE_ZIP", $Fixture, "Process")

  $Bytes = [IO.File]::ReadAllBytes($EnvFile)
  Assert-True (-not ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)) ".env.local contains a UTF-8 BOM"
  $Acl = Get-Acl $EnvFile
  $AclIdentities = @($Acl.Access | ForEach-Object {
    $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
  })
  $CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  Assert-True ($AclIdentities -contains $CurrentSid) ".env.local ACL is missing the current user"
  $CurrentFullControl = @($Acl.Access | Where-Object {
    $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $CurrentSid -and
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    (($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl)
  })
  Assert-True ($CurrentFullControl.Count -gt 0) ".env.local ACL does not grant the current user full control"

  $ExpectedSecret = $Secret
  . $script:Installer
  Assert-True ($Secret -ceq $ExpectedSecret) "test secret variable changed after dot-sourcing installer"
  $DotEnvRoundTrip = "slash\quote`"carriage`rtab`t"
  Assert-True ((ConvertFrom-DotEnvValue (ConvertTo-DotEnvValue $DotEnvRoundTrip)) -ceq $DotEnvRoundTrip) "dotenv escaping did not round-trip"
  $PrimaryRepoDir = $RepoDir
  $RoundTripRepo = Join-Path $TempRoot "dotenv-roundtrip"
  New-Item -ItemType Directory -Force -Path $RoundTripRepo | Out-Null
  try {
    $script:RepoDir = $RoundTripRepo
    $script:KeyOnlyApiKey = $DotEnvRoundTrip
    Write-KeyOnlyEnvironment
    Import-DotEnv (Join-Path $RoundTripRepo ".env.local")
    Assert-True ($env:OPENAI_IMAGE_API_KEY -ceq $DotEnvRoundTrip) "stored complex dotenv value did not round-trip"
  } finally {
    $script:RepoDir = $PrimaryRepoDir
    $script:KeyOnlyApiKey = ""
  }
  $StoredKeyLine = @(Get-Content $EnvFile | Where-Object { $_.StartsWith("OPENAI_IMAGE_API_KEY=") })
  Assert-True ($StoredKeyLine.Count -eq 1) "stored dotenv key line count is not one"
  $StoredKeyMatch = [regex]::Match($StoredKeyLine[0], '^OPENAI_IMAGE_API_KEY=(.*)$')
  Assert-True ($StoredKeyMatch.Success) "stored dotenv key line is malformed"
  $RawStoredKey = $StoredKeyMatch.Groups[1].Value
  $ExpectedStoredKey = ConvertTo-DotEnvValue $ExpectedSecret
  Assert-True ($RawStoredKey.Trim().StartsWith('"')) "stored dotenv value is missing its opening quote"
  Assert-True ($RawStoredKey.Trim().EndsWith('"')) "stored dotenv value is missing its closing quote"
  $StructuralDecodedKey = ConvertFrom-DotEnvValue ($RawStoredKey.Trim())
  Assert-True ($StructuralDecodedKey -cne ($ExpectedSecret + "`r`nignored-second-line`r`n")) "stored API Key consumed the complete redirected input"
  Assert-True ($StructuralDecodedKey.Length -eq 0 -or [int]$StructuralDecodedKey[0] -ne 0xFEFF) "stored API Key contains a redirected-input BOM"
  Assert-True ($RawStoredKey.Trim().Length -eq $ExpectedStoredKey.Length) "stored dotenv value length differs from codec output"
  Assert-True ($RawStoredKey.Trim().Substring(1, $RawStoredKey.Trim().Length - 2) -ceq $ExpectedSecret) "stored dotenv payload differs from input"
  Assert-True ($RawStoredKey.Trim() -ceq $ExpectedStoredKey) "stored dotenv encoding differs from codec output"
  $DecodedStoredKey = ConvertFrom-DotEnvValue ($RawStoredKey.Trim())
  Assert-True ($DecodedStoredKey -cne "old-key-must-be-ignored") "installer stored the ambient API Key"
  Assert-True ($DecodedStoredKey -ceq $ExpectedSecret) "stored dotenv value did not decode"
  Import-DotEnv $EnvFile
  Assert-True ($env:OPENAI_IMAGE_BASE_URL -eq "https://api.schyler.top") "stored base URL is not fixed"
  Assert-True ($env:OPENAI_IMAGE_API_KEY -eq $Secret) "stored API Key did not round-trip"

  $SecretText = "sk-test-pipeline-first-line"
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_EXPECTED_API_KEY", $SecretText, "Process")
  $PipelineOutput = @($SecretText, "ignored-second-line") |
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Harness -KeyOnly 2>&1 |
    Out-String
  $PipelineExitCode = $LASTEXITCODE
  Assert-True ($PipelineExitCode -eq 0) "pipeline key-only install failed"
  Assert-True ($PipelineOutput.Contains("Verification: OK")) "pipeline verification marker missing"
  Assert-True (-not $PipelineOutput.Contains($SecretText)) "pipeline API Key leaked to output"
  $PipelineKeyLine = @(Get-Content $EnvFile | Where-Object { $_.StartsWith("OPENAI_IMAGE_API_KEY=") })
  Assert-True ($PipelineKeyLine.Count -eq 1) "pipeline stored dotenv key line count is not one"
  $PipelineKeyMatch = [regex]::Match($PipelineKeyLine[0], '^OPENAI_IMAGE_API_KEY=(.*)$')
  Assert-True ($PipelineKeyMatch.Success) "pipeline stored dotenv key line is malformed"
  $PipelineDecodedKey = ConvertFrom-DotEnvValue ($PipelineKeyMatch.Groups[1].Value.Trim())
  Assert-True ($PipelineDecodedKey -ceq $SecretText) "pipeline stored API Key did not exactly match the first input line"
  Assert-True ($PipelineDecodedKey -cne ($SecretText + "`r`nignored-second-line")) "pipeline stored API Key consumed more than one input line"

  Assert-True ((Get-ArchName "AMD64") -eq "amd64") "AMD64 mapping failed"
  Assert-True ((Get-ArchName "ARM64") -eq "arm64") "ARM64 mapping failed"
  $Unsupported = $false
  try { [void](Get-ArchName "RISCV64") } catch { $Unsupported = $true }
  Assert-True $Unsupported "unsupported architecture unexpectedly succeeded"

  $EnvHash = (Get-FileHash $EnvFile -Algorithm SHA256).Hash
  $Blank = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText "   `r`n"
  Assert-True ($Blank.ExitCode -ne 0) "blank API Key unexpectedly succeeded"
  Assert-True (((Get-FileHash $EnvFile -Algorithm SHA256).Hash) -eq $EnvHash) "blank API Key changed .env.local"

  $Conflict = Invoke-TestInstaller -InstallerArgs @("-KeyOnly", "-BaseUrl", "https://example.invalid")
  Assert-True ($Conflict.ExitCode -ne 0) "conflicting key-only options unexpectedly succeeded"

  $BinaryFile = Join-Path $Repo "dist\image2-mcp.exe"
  $BinaryHash = (Get-FileHash $BinaryFile -Algorithm SHA256).Hash
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_RELEASE_ZIP", (Join-Path $TempRoot "missing.zip"), "Process")
  $DownloadFailure = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText ($Secret + "`r`n")
  Assert-True ($DownloadFailure.ExitCode -ne 0) "missing Release fixture unexpectedly succeeded"
  Assert-True (((Get-FileHash $BinaryFile -Algorithm SHA256).Hash) -eq $BinaryHash) "failed download replaced working binary"

  $ArrayHome = Join-Path $TempRoot "array-home"
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_EXPECTED_API_KEY", $Secret, "Process")
  New-Item -ItemType Directory -Force -Path (Join-Path $ArrayHome ".codex") | Out-Null
  $ArrayConfig = Join-Path $ArrayHome ".codex\config.toml"
  [IO.File]::WriteAllText($ArrayConfig, "[[mcp_servers.image2]]`r`ncommand = `"ambiguous`"`r`n", (New-Object Text.UTF8Encoding($false)))
  [Environment]::SetEnvironmentVariable("HOME", $ArrayHome, "Process")
  [Environment]::SetEnvironmentVariable("USERPROFILE", $ArrayHome, "Process")
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_RELEASE_ZIP", $Fixture, "Process")
  $ArrayHash = (Get-FileHash $ArrayConfig -Algorithm SHA256).Hash
  $ArrayResult = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText ($Secret + "`r`n")
  Assert-True ($ArrayResult.ExitCode -ne 0) "Image2 array table unexpectedly succeeded"
  Assert-True ($ArrayResult.Output.Contains("unsupported Image2 TOML table header")) "array-table error is unclear"
  Assert-True (((Get-FileHash $ArrayConfig -Algorithm SHA256).Hash) -eq $ArrayHash) "array-table config changed"

  $SpacedHome = Join-Path $TempRoot "spaced-home"
  New-Item -ItemType Directory -Force -Path (Join-Path $SpacedHome ".codex") | Out-Null
  $SpacedConfig = Join-Path $SpacedHome ".codex\config.toml"
  [IO.File]::WriteAllText($SpacedConfig, @'
model = "gpt-5"

[mcp_servers . image2]
command = "C:\spaced\old-runner.ps1"

[mcp_servers . image2 . env]
OLD = "spaced value"

[mcp_servers.image20]
command = "C:\keep\image20-runner.exe"
'@, (New-Object Text.UTF8Encoding($false)))
  [Environment]::SetEnvironmentVariable("HOME", $SpacedHome, "Process")
  [Environment]::SetEnvironmentVariable("USERPROFILE", $SpacedHome, "Process")
  $SpacedResult = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText ($Secret + "`r`n")
  Assert-True ($SpacedResult.ExitCode -eq 0) "spaced Image2 tables were not replaced"
  $SpacedText = [IO.File]::ReadAllText($SpacedConfig)
  Assert-True (-not $SpacedText.Contains('C:\spaced\old-runner.ps1')) "spaced Image2 root config remains"
  Assert-True (-not $SpacedText.Contains('OLD = "spaced value"')) "spaced Image2 descendant config remains"
  Assert-True ($SpacedText.Contains('[mcp_servers.image20]')) "spaced replacement removed image20"

  $QuotedHome = Join-Path $TempRoot "quoted-home"
  New-Item -ItemType Directory -Force -Path (Join-Path $QuotedHome ".codex") | Out-Null
  $QuotedConfig = Join-Path $QuotedHome ".codex\config.toml"
  [IO.File]::WriteAllText($QuotedConfig, @'
["mcp_servers"."image2"]
command = "C:\quoted\old-runner.ps1"
'@, (New-Object Text.UTF8Encoding($false)))
  [Environment]::SetEnvironmentVariable("HOME", $QuotedHome, "Process")
  [Environment]::SetEnvironmentVariable("USERPROFILE", $QuotedHome, "Process")
  $QuotedHash = (Get-FileHash $QuotedConfig -Algorithm SHA256).Hash
  $QuotedResult = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText ($Secret + "`r`n")
  Assert-True ($QuotedResult.ExitCode -ne 0) "quoted Image2 table unexpectedly succeeded"
  Assert-True ($QuotedResult.Output.Contains("unsupported Image2 TOML table header")) "quoted Image2 table error is unclear"
  Assert-True (((Get-FileHash $QuotedConfig -Algorithm SHA256).Hash) -eq $QuotedHash) "quoted Image2 config changed"

  function Assert-ConflictingAssignmentRefused([string]$Name, [string]$Config) {
    $ConflictHome = Join-Path $TempRoot ("conflicting-assignment-" + $Name)
    $ConflictConfig = Join-Path $ConflictHome ".codex\config.toml"
    New-Item -ItemType Directory -Force -Path (Join-Path $ConflictHome ".codex") | Out-Null
    [IO.File]::WriteAllText($ConflictConfig, $Config, (New-Object Text.UTF8Encoding($false)))
    $ConfigHash = Get-FileFingerprint $ConflictConfig
    $EnvFingerprint = Get-FileFingerprint $EnvFile
    $BinaryFingerprint = Get-FileFingerprint $BinaryFile
    [Environment]::SetEnvironmentVariable("HOME", $ConflictHome, "Process")
    [Environment]::SetEnvironmentVariable("USERPROFILE", $ConflictHome, "Process")
    $Result = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText ($Secret + "`r`n")
    Assert-True ($Result.ExitCode -ne 0) "conflicting Image2 TOML assignment $Name unexpectedly succeeded"
    Assert-True ($Result.Output.Contains("unsupported conflicting Image2 TOML assignment")) "conflicting Image2 TOML assignment $Name error is unclear"
    Assert-True (-not $Result.Output.Contains("old")) "conflicting Image2 TOML assignment $Name exposed config content"
    Assert-True (-not $Result.Output.Contains("OPENAI_IMAGE_API_KEY:")) "conflicting Image2 TOML assignment $Name prompted for an API Key"
    Assert-True ((Get-FileFingerprint $ConflictConfig) -eq $ConfigHash) "conflicting Image2 TOML assignment $Name changed config"
    Assert-True ((Get-FileFingerprint $EnvFile) -eq $EnvFingerprint) "conflicting Image2 TOML assignment $Name changed .env.local"
    Assert-True ((Get-FileFingerprint $BinaryFile) -eq $BinaryFingerprint) "conflicting Image2 TOML assignment $Name changed binary"
  }

  Assert-ConflictingAssignmentRefused "dotted" @'
mcp_servers.image2.command = "old"
'@

  Assert-ConflictingAssignmentRefused "quoted-dotted" @'
"mcp_servers" . "image2" . command = "old"
'@

  Assert-ConflictingAssignmentRefused "inline" @'
mcp_servers = { image2 = { command = "old" } }
'@

  Assert-ConflictingAssignmentRefused "table-dotted" @'
[mcp_servers]
image2.command = "old"
'@

  Assert-ConflictingAssignmentRefused "quoted-table-inline" @'
[mcp_servers]
'image2' = { command = "old" }
'@

  $SiblingAssignmentHome = Join-Path $TempRoot "sibling-assignment-home"
  $SiblingAssignmentConfig = Join-Path $SiblingAssignmentHome ".codex\config.toml"
  New-Item -ItemType Directory -Force -Path (Join-Path $SiblingAssignmentHome ".codex") | Out-Null
  [IO.File]::WriteAllText($SiblingAssignmentConfig, @'
mcp_servers.keep.command = "ok"
"mcp_servers" . "keep-quoted" . command = "quoted ok"
'@, (New-Object Text.UTF8Encoding($false)))
  [Environment]::SetEnvironmentVariable("HOME", $SiblingAssignmentHome, "Process")
  [Environment]::SetEnvironmentVariable("USERPROFILE", $SiblingAssignmentHome, "Process")
  $SiblingAssignmentResult = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText ($Secret + "`r`n")
  Assert-True ($SiblingAssignmentResult.ExitCode -eq 0) "root dotted sibling assignments were not accepted"
  Assert-True ($SiblingAssignmentResult.Output.Contains("Verification: OK")) "root dotted sibling verification marker missing"
  $SiblingAssignmentLines = [IO.File]::ReadAllLines($SiblingAssignmentConfig)
  Assert-True ($SiblingAssignmentLines -ccontains 'mcp_servers.keep.command = "ok"') "root dotted sibling assignment was not preserved"
  Assert-True ($SiblingAssignmentLines -ccontains '"mcp_servers" . "keep-quoted" . command = "quoted ok"') "quoted root dotted sibling assignment was not preserved"

  Write-Host "PASS: PowerShell key-only installer"
} finally {
  foreach ($Name in $SavedEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($Name, $SavedEnvironment[$Name], "Process")
  }
  if (Test-Path $TempRoot) {
    Remove-Item -Recurse -Force $TempRoot
  }
}
