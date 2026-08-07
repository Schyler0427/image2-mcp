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

function Invoke-TestInstaller([string[]]$InstallerArgs, [string]$InputText = "") {
  $PowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $Info = New-Object System.Diagnostics.ProcessStartInfo
  $Info.FileName = $PowerShell
  $QuotedInstaller = '"' + $script:Installer.Replace('"', '\"') + '"'
  $Info.Arguments = "-NoProfile -ExecutionPolicy Bypass -File $QuotedInstaller " + ($InstallerArgs -join " ")
  $Info.UseShellExecute = $false
  $Info.RedirectStandardInput = $true
  $Info.RedirectStandardOutput = $true
  $Info.RedirectStandardError = $true
  $Info.CreateNoWindow = $true
  $Process = New-Object System.Diagnostics.Process
  $Process.StartInfo = $Info
  [void]$Process.Start()
  if ($InputText.Length -gt 0) {
    $InputBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($InputText)
    $Process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
    $Process.StandardInput.BaseStream.Flush()
  }
  $Process.StandardInput.Close()
  $Stdout = $Process.StandardOutput.ReadToEnd()
  $Stderr = $Process.StandardError.ReadToEnd()
  $Process.WaitForExit()
  return [PSCustomObject]@{
    ExitCode = $Process.ExitCode
    Output = $Stdout + $Stderr
  }
}

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("image2-mcp-test-" + [Guid]::NewGuid())
$TestHome = Join-Path $TempRoot "home"
$Repo = Join-Path $TempRoot "repo"
$Payload = Join-Path $TempRoot "payload"
$Fixture = Join-Path $TempRoot "image2-mcp.zip"
$script:Installer = Join-Path $Repo "install.ps1"
$ConfigFile = Join-Path $TestHome ".codex\config.toml"
$EnvFile = Join-Path $Repo ".env.local"

$SavedEnvironment = @{}
foreach ($Name in @("HOME", "USERPROFILE", "LOCALAPPDATA", "IMAGE2_MCP_TEST_RELEASE_ZIP", "OPENAI_IMAGE_BASE_URL", "OPENAI_IMAGE_API_KEY")) {
  $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
}

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $TestHome ".codex"), (Join-Path $Repo "scripts"), $Payload | Out-Null
  Copy-Item (Join-Path $Root "install.ps1") $script:Installer
  Copy-Item (Join-Path $Root "scripts\run-image2-mcp.ps1") (Join-Path $Repo "scripts\run-image2-mcp.ps1")
  Copy-Item $env:ComSpec (Join-Path $Payload "image2-mcp.exe")
  Compress-Archive -Path (Join-Path $Payload "image2-mcp.exe") -DestinationPath $Fixture
  Assert-InstallerParses

  [Environment]::SetEnvironmentVariable("HOME", $TestHome, "Process")
  [Environment]::SetEnvironmentVariable("USERPROFILE", $TestHome, "Process")
  [Environment]::SetEnvironmentVariable("LOCALAPPDATA", (Join-Path $TestHome "AppData\Local"), "Process")
  [Environment]::SetEnvironmentVariable("IMAGE2_MCP_TEST_RELEASE_ZIP", $Fixture, "Process")
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
  $Result = Invoke-TestInstaller -InstallerArgs @("-KeyOnly") -InputText ($Secret + "`r`nignored-second-line`r`n")
  Assert-True ($Result.ExitCode -eq 0) "Key-only install failed: $($Result.Output)"
  Assert-True ($Result.Output.Contains("Test input mode: redirected")) "key-only installer did not use redirected input"
  Assert-True ($Result.Output.Contains("Verification: OK")) "verification marker missing"
  Assert-True (-not $Result.Output.Contains($Secret)) "API Key leaked to output"
  Assert-True ($Result.Output.Contains("image2-mcp_windows_")) "Release asset name was not reported"
  Assert-True ($Result.Output.Contains("https://github.com/Schyler0427/image2-mcp/releases/latest/download/")) "Release repository is not fixed"
  Assert-True ($Result.Output.Contains("Base URL: https://api.schyler.top")) "reported base URL is not fixed"

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

  $Bytes = [IO.File]::ReadAllBytes($EnvFile)
  Assert-True (-not ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)) ".env.local contains a UTF-8 BOM"
  $Acl = Get-Acl $EnvFile
  Assert-True ($Acl.AreAccessRulesProtected) ".env.local ACL still inherits permissions"
  $AclIdentities = @($Acl.Access | ForEach-Object {
    $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
  })
  foreach ($ExpectedIdentity in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, "S-1-5-18", "S-1-5-32-544")) {
    Assert-True ($AclIdentities -contains $ExpectedIdentity) ".env.local ACL is missing $ExpectedIdentity"
  }

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
  $LeadingBomCount = 0
  while ($LeadingBomCount -lt $StructuralDecodedKey.Length -and $StructuralDecodedKey[$LeadingBomCount] -eq [char]0xFEFF) {
    $LeadingBomCount++
  }
  Assert-True ($LeadingBomCount -eq 0) "stored API Key contains $LeadingBomCount redirected-input BOM characters"
  Assert-True (-not ($StructuralDecodedKey.StartsWith($ExpectedSecret) -and $StructuralDecodedKey.Length -gt $ExpectedSecret.Length)) "stored API Key contains an extra suffix"
  if ($StructuralDecodedKey.EndsWith($ExpectedSecret) -and $StructuralDecodedKey.Length -gt $ExpectedSecret.Length) {
    $PrefixLength = $StructuralDecodedKey.Length - $ExpectedSecret.Length
    $PrefixCodeUnits = @(($StructuralDecodedKey.Substring(0, $PrefixLength)).ToCharArray() | ForEach-Object { [int]$_ })
    $PrefixCategory = switch ($PrefixCodeUnits -join ",") {
      "239,187,191" { "UTF-8 BOM decoded as Windows-1252"; break }
      "8745,9559,9488" { "UTF-8 BOM decoded as OEM 437"; break }
      "180,9559,9488" { "UTF-8 BOM decoded as OEM 850"; break }
      default { "unclassified $PrefixLength-code-unit prefix" }
    }
    throw "FAIL: stored API Key contains $PrefixCategory"
  }
  Assert-True ($RawStoredKey.Trim().Length -eq $ExpectedStoredKey.Length) "stored dotenv value length differs from codec output"
  Assert-True ($RawStoredKey.Trim().Substring(1, $RawStoredKey.Trim().Length - 2) -ceq $ExpectedSecret) "stored dotenv payload differs from input"
  Assert-True ($RawStoredKey.Trim() -ceq $ExpectedStoredKey) "stored dotenv encoding differs from codec output"
  $DecodedStoredKey = ConvertFrom-DotEnvValue ($RawStoredKey.Trim())
  Assert-True ($DecodedStoredKey -cne "old-key-must-be-ignored") "installer stored the ambient API Key"
  Assert-True ($DecodedStoredKey -ceq $ExpectedSecret) "stored dotenv value did not decode"
  Import-DotEnv $EnvFile
  Assert-True ($env:OPENAI_IMAGE_BASE_URL -eq "https://api.schyler.top") "stored base URL is not fixed"
  Assert-True ($env:OPENAI_IMAGE_API_KEY -eq $Secret) "stored API Key did not round-trip"
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

  Write-Host "PASS: PowerShell key-only installer"
} finally {
  foreach ($Name in $SavedEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($Name, $SavedEnvironment[$Name], "Process")
  }
  if (Test-Path $TempRoot) {
    Remove-Item -Recurse -Force $TempRoot
  }
}
