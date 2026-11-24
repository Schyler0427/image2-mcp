param(
  [switch]$KeyOnly,
  [switch]$Offline,
  [switch]$Interactive,
  [switch]$ConfigureCodex,
  [switch]$ForceConfig,
  [string]$BaseUrl = $(if ($env:OPENAI_IMAGE_BASE_URL) { $env:OPENAI_IMAGE_BASE_URL } else { "https://api.schyler.top" }),
  [switch]$Prebuilt,
  [switch]$SkipTests,
  [switch]$Smoke,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
$KeyOnlyBaseUrl = "https://api.schyler.top"
$KeyOnlyRepo = "Schyler0427/image2-mcp"
$BoundInstallerParameters = @{} + $PSBoundParameters
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:KeyOnlyApiKey = ""
$script:KeyOnlyGeminiApiKey = ""

function Enable-Image2Tls12 {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Show-Help {
  @"
Usage: powershell -ExecutionPolicy Bypass -File .\install.ps1 [options]

Install and optionally configure the Image2 MCP server for Codex on Windows.

Options:
  -KeyOnly          Prompt for independent Image2 and Gemini API keys and install the fixed Codex configuration.
  -Offline          Use the bundled binary with -KeyOnly; never download or build.
  -Interactive      Prompt for base URL and optional fresh provider keys (at least one), then write .env.local.
  -ConfigureCodex   Append an image2 MCP server block to ~/.codex/config.toml.
  -ForceConfig      Replace existing [mcp_servers.image2] config block.
  -BaseUrl URL      Set OPENAI_IMAGE_BASE_URL in .env.local or Codex config.
  -Prebuilt         Download a GitHub Release binary even when Go is installed.
  -SkipTests        Build without running go test ./...
  -Smoke            Run a real image-generation smoke test after build.
  -Help             Show this help.

Environment:
  OPENAI_IMAGE_API_KEY   Image2 credential; required for Image2 requests and -Smoke.
  GEMINI_IMAGE_API_KEY   Independent Gemini credential; required for Gemini requests.
  GEMINI_IMAGE_BASE_URL  Gemini API base URL; defaults to https://api.schyler.top.
  OPENAI_IMAGE_BASE_URL  Optional default base URL; defaults to https://api.schyler.top.
  IMAGE2_MCP_REPO        Optional GitHub repo slug, for example owner/image2-mcp.
"@
}

function ConvertTo-DotEnvValue([string]$Value) {
  if ($Value.Contains([char]0)) {
    throw "dotenv values cannot contain NUL"
  }
  $Builder = New-Object Text.StringBuilder
  foreach ($Char in $Value.ToCharArray()) {
    if ($Char -eq '\') {
      [void]$Builder.Append('\\')
    } elseif ($Char -eq '"') {
      [void]$Builder.Append('\"')
    } elseif ($Char -eq "`r") {
      [void]$Builder.Append('\r')
    } elseif ($Char -eq "`n") {
      [void]$Builder.Append('\n')
    } elseif ($Char -eq "`t") {
      [void]$Builder.Append('\t')
    } else {
      [void]$Builder.Append($Char)
    }
  }
  return '"' + $Builder.ToString() + '"'
}

function ConvertFrom-DotEnvValue([string]$Value) {
  if (-not ($Value.StartsWith('"') -and $Value.EndsWith('"'))) {
    if ($Value.StartsWith("'") -and $Value.EndsWith("'")) {
      return $Value.Substring(1, $Value.Length - 2)
    }
    return $Value
  }

  $Inner = $Value.Substring(1, $Value.Length - 2)
  $Builder = New-Object Text.StringBuilder
  for ($Index = 0; $Index -lt $Inner.Length; $Index++) {
    $Char = $Inner[$Index]
    if ($Char -ne '\') {
      [void]$Builder.Append($Char)
      continue
    }
    $Index++
    if ($Index -ge $Inner.Length) {
      throw "invalid trailing escape in dotenv value"
    }
    switch ($Inner[$Index]) {
      '\' { [void]$Builder.Append('\') }
      '"' { [void]$Builder.Append('"') }
      'r' { [void]$Builder.Append("`r") }
      'n' { [void]$Builder.Append("`n") }
      't' { [void]$Builder.Append("`t") }
      default { throw "unsupported escape in dotenv value" }
    }
  }
  return $Builder.ToString()
}

function Import-DotEnv([string]$Path) {
  if (-not (Test-Path $Path)) {
    return
  }
  foreach ($Line in Get-Content $Path) {
    $Trimmed = $Line.Trim()
    if ($Trimmed -eq "" -or $Trimmed.StartsWith("#")) {
      continue
    }
    $Parts = $Trimmed.Split("=", 2)
    if ($Parts.Count -ne 2) {
      continue
    }
    $Name = $Parts[0].Trim()
    $Value = ConvertFrom-DotEnvValue ($Parts[1].Trim())
    [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
  }
}

function Set-RestrictedFileAcl([string]$Path) {
  # Preserve the profile's inherited DACL/SACL; replacing the descriptor or
  # disabling inheritance requires privileges ordinary users do not have.
  $Security = Get-Acl -Path $Path
  $CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $CurrentSid,
    [System.Security.AccessControl.FileSystemRights]::FullControl,
    [System.Security.AccessControl.AccessControlType]::Allow
  )
  $Security.SetAccessRule($Rule)
  Set-Acl -Path $Path -AclObject $Security
}

function Move-FileAtomically([string]$Source, [string]$Destination) {
  if (Test-Path $Destination) {
    $Backup = "$Destination.bak.$([Guid]::NewGuid().ToString('N'))"
    try {
      [IO.File]::Replace($Source, $Destination, $Backup)
    } finally {
      if (Test-Path $Backup) {
        Remove-Item -Force $Backup
      }
    }
  } else {
    [IO.File]::Move($Source, $Destination)
  }
}

function Write-KeyOnlyEnvironment([string]$ImageBaseUrl = $KeyOnlyBaseUrl) {
  $Target = Join-Path $RepoDir ".env.local"
  $Temp = Join-Path $RepoDir (".env.local.tmp." + [Guid]::NewGuid().ToString("N"))
  $Encoding = New-Object Text.UTF8Encoding($false)
  try {
    $Lines = @(
      "OPENAI_IMAGE_BASE_URL=$(ConvertTo-DotEnvValue $ImageBaseUrl)",
      "OPENAI_IMAGE_API_KEY=$(ConvertTo-DotEnvValue $script:KeyOnlyApiKey)",
      "GEMINI_IMAGE_BASE_URL=$(ConvertTo-DotEnvValue $ImageBaseUrl)",
      "GEMINI_IMAGE_API_KEY=$(ConvertTo-DotEnvValue $script:KeyOnlyGeminiApiKey)"
    )
    [IO.File]::WriteAllLines($Temp, $Lines, $Encoding)
    Set-RestrictedFileAcl $Temp
    Move-FileAtomically $Temp $Target
    Set-RestrictedFileAcl $Target
  } finally {
    if (Test-Path $Temp) {
      Remove-Item -Force $Temp
    }
  }
}

function Assert-ImageApiKey([AllowNull()][string]$Value, [string]$Name) {
  if ($null -eq $Value) { throw "missing API key input line" }
  if ($Value.Contains("`r") -or $Value.Contains("`n") -or $Value.Contains([char]0)) {
    throw "$Name must be one line and cannot contain NUL"
  }
  if ([Text.Encoding]::UTF8.GetByteCount($Value) -gt 1024) {
    throw "$Name cannot exceed 1024 UTF-8 bytes"
  }
}

function Read-ImageApiKey([string]$Name) {
  $InputIsRedirected = [Console]::IsInputRedirected
  if ($InputIsRedirected) {
    Write-Host -NoNewline ($Name + ": ")
    $Value = [Console]::In.ReadLine()
    if ($null -eq $Value) {
      throw "supply both API key input lines; either line may be empty"
    }
    Write-Host ""
  } else {
    $Secret = Read-Host $Name -AsSecureString
    $Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
      $Value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
    }
  }

  if ($InputIsRedirected -and $null -ne $Value -and $Value.Length -gt 0 -and [int]$Value[0] -eq 0xFEFF) {
    $Value = $Value.Substring(1)
  }
  Assert-ImageApiKey $Value $Name
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  return $Value
}

function Read-KeyOnce {
  # Always request both input lines (either may be blank), including upgrades. Never use shell
  # credentials or old .env.local values as a fallback for either provider.
  $ImageApiKey = Read-ImageApiKey "OPENAI_IMAGE_API_KEY"
  $GeminiApiKey = Read-ImageApiKey "GEMINI_IMAGE_API_KEY"
  if ([string]::IsNullOrWhiteSpace($ImageApiKey) -and [string]::IsNullOrWhiteSpace($GeminiApiKey)) {
    throw "at least one Image2 or Gemini API Key is required"
  }
  $script:KeyOnlyApiKey = $ImageApiKey
  $script:KeyOnlyGeminiApiKey = $GeminiApiKey
}

function Get-GitHubRepoSlug {
  if ($env:IMAGE2_MCP_REPO) {
    return $env:IMAGE2_MCP_REPO
  }
  try {
    $Remote = git remote get-url origin 2>$null
  } catch {
    $Remote = ""
  }
  if ($Remote -match '^git@github\.com:(.+?)(\.git)?$') {
    return $Matches[1] -replace '\.git$', ''
  }
  if ($Remote -match '^https://github\.com/(.+?)(\.git)?$') {
    return $Matches[1] -replace '\.git$', ''
  }
  throw "cannot infer GitHub repo. Set IMAGE2_MCP_REPO=owner/image2-mcp or install Go."
}

function Get-ArchName([string]$Architecture = $env:PROCESSOR_ARCHITECTURE) {
  switch ($Architecture.ToUpperInvariant()) {
    "AMD64" { return "amd64" }
    "ARM64" { return "arm64" }
    default { throw "unsupported architecture for prebuilt download: $Architecture" }
  }
}

function Install-Prebuilt {
  $Repo = Get-GitHubRepoSlug
  $Arch = Get-ArchName
  $Asset = "image2-mcp_windows_${Arch}.zip"
  $Url = if ($KeyOnly) {
    "https://github.com/${Repo}/releases/download/v0.4.4/${Asset}"
  } else {
    "https://github.com/${Repo}/releases/latest/download/${Asset}"
  }
  $Dist = Join-Path $RepoDir "dist"
  New-Item -ItemType Directory -Force -Path $Dist | Out-Null
  $TempDir = Join-Path $Dist (".image2-mcp." + [Guid]::NewGuid().ToString("N"))
  $ZipPath = Join-Path $TempDir $Asset
  $ExtractDir = Join-Path $TempDir "extract"
  $StagedBinary = Join-Path $ExtractDir "image2-mcp.exe"
  $TargetBinary = Join-Path $Dist "image2-mcp.exe"
  New-Item -ItemType Directory -Force -Path $TempDir, $ExtractDir | Out-Null
  try {
    Write-Host "==> Downloading prebuilt binary: $Url"
    Enable-Image2Tls12
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 90 -Uri $Url -OutFile $ZipPath
    Assert-Image2PrebuiltZip $ZipPath
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force
    $StagedItem = Get-Item -LiteralPath $StagedBinary -Force -ErrorAction SilentlyContinue
    if ($null -eq $StagedItem -or $StagedItem.PSIsContainer -or
        (Test-Image2ReparsePoint $StagedItem) -or $StagedItem.Length -eq 0) {
      throw "prebuilt archive does not contain a non-empty image2-mcp.exe"
    }
    Move-FileAtomically $StagedBinary $TargetBinary
  } finally {
    if (Test-Path $TempDir) {
      Remove-Item -Recurse -Force $TempDir
    }
  }
}

function Test-Image2ReparsePoint([IO.FileSystemInfo]$Item) {
  return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-Image2PrebuiltZip([string]$ZipPath) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
  $Zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    if ($Zip.Entries.Count -ne 1) {
      throw "prebuilt archive must contain exactly one image2-mcp.exe file"
    }
    $Entry = $Zip.Entries[0]
    $Name = ([string]$Entry.FullName).Replace('\', '/')
    if ($Name -cne "image2-mcp.exe" -or $Entry.Name.Length -eq 0) {
      throw "prebuilt archive contains an unexpected path"
    }
    $ExternalAttributes = [int]$Entry.ExternalAttributes
    $DosAttributes = $ExternalAttributes -band 0xFFFF
    $UnixType = ($ExternalAttributes -shr 16) -band 0xF000
    if (($DosAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $UnixType -eq 0xA000) {
      throw "prebuilt archive contains a link or reparse entry"
    }
    if (($DosAttributes -band [int][IO.FileAttributes]::Directory) -ne 0 -or
        $UnixType -eq 0x4000) {
      throw "prebuilt archive contains a directory entry"
    }
    if ($UnixType -ne 0 -and $UnixType -ne 0x8000) {
      throw "prebuilt archive contains an unsupported entry type"
    }
  } finally {
    $Zip.Dispose()
  }
}

function Test-Image2ConfigHeader([string]$Line) {
  return $Line -match '^\s*\[\s*mcp_servers\s*\.\s*image2(?:\s*\.\s*[^\]]+)?\]\s*(?:#.*)?$'
}

function Test-TomlTableHeader([string]$Line) {
  return $Line -match '^\s*\[[^\[\]]+\]\s*(?:#.*)?$'
}

function Test-TomlArrayTableHeader([string]$Line) {
  return $Line -match '^\s*\[\[[^\[\]]+\]\]\s*(?:#.*)?$'
}

function Get-TomlHeaderKeySegments([string]$Line) {
  $Match = [regex]::Match($Line, '^\s*\[(?<Body>[^\[\]]+)\]\s*(?:#.*)?$')
  if (-not $Match.Success) {
    $Match = [regex]::Match($Line, '^\s*\[\[(?<Body>[^\[\]]+)\]\]\s*(?:#.*)?$')
  }
  if (-not $Match.Success) {
    return $null
  }

  return (Get-TomlKeySegments $Match.Groups['Body'].Value)
}

function Get-TomlKeySegments([string]$Text) {
  $Segments = New-Object System.Collections.Generic.List[string]
  $Index = 0
  while ($true) {
    while ($Index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$Index])) {
      $Index++
    }
    if ($Index -ge $Text.Length) {
      return $null
    }

    $Builder = New-Object Text.StringBuilder
    if ($Text[$Index] -eq '"') {
      $Index++
      $Closed = $false
      while ($Index -lt $Text.Length) {
        $Char = $Text[$Index]
        if ($Char -eq '"') {
          $Index++
          $Closed = $true
          break
        }
        if ($Char -ne '\') {
          [void]$Builder.Append($Char)
          $Index++
          continue
        }
        $Index++
        if ($Index -ge $Text.Length) {
          return $null
        }
        $Escape = $Text[$Index]
        if ($Escape -eq 'u' -or $Escape -eq 'U') {
          $Digits = if ($Escape -eq 'u') { 4 } else { 8 }
          if ($Index + $Digits -ge $Text.Length) {
            return $null
          }
          try {
            $Code = [Convert]::ToInt32($Text.Substring($Index + 1, $Digits), 16)
          } catch {
            return $null
          }
          if ($Code -gt 0xFFFF) {
            return $null
          }
          [void]$Builder.Append([char]$Code)
          $Index += $Digits + 1
          continue
        }
        switch ($Escape) {
          'b' { [void]$Builder.Append([char]8) }
          't' { [void]$Builder.Append("`t") }
          'n' { [void]$Builder.Append("`n") }
          'f' { [void]$Builder.Append([char]12) }
          'r' { [void]$Builder.Append("`r") }
          '"' { [void]$Builder.Append('"') }
          '\' { [void]$Builder.Append('\') }
          '/' { [void]$Builder.Append('/') }
          default { return $null }
        }
        $Index++
      }
      if (-not $Closed) {
        return $null
      }
    } elseif ($Text[$Index] -eq "'") {
      $Index++
      while ($Index -lt $Text.Length -and $Text[$Index] -ne "'") {
        [void]$Builder.Append($Text[$Index])
        $Index++
      }
      if ($Index -ge $Text.Length) {
        return $null
      }
      $Index++
    } else {
      while ($Index -lt $Text.Length -and ($Text[$Index] -match '[A-Za-z0-9_-]')) {
        [void]$Builder.Append($Text[$Index])
        $Index++
      }
      if ($Builder.Length -eq 0) {
        return $null
      }
    }

    $Segments.Add($Builder.ToString())
    while ($Index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$Index])) {
      $Index++
    }
    if ($Index -eq $Text.Length) {
      return $Segments.ToArray()
    }
    if ($Text[$Index] -ne '.') {
      return $null
    }
    $Index++
  }
}

function Get-TomlAssignmentKeySegments([string]$Line) {
  $Quote = [char]0
  $Escaped = $false
  for ($Index = 0; $Index -lt $Line.Length; $Index++) {
    $Char = $Line[$Index]
    if ($Quote -eq '"') {
      if ($Escaped) {
        $Escaped = $false
      } elseif ($Char -eq '\') {
        $Escaped = $true
      } elseif ($Char -eq $Quote) {
        $Quote = [char]0
      }
      continue
    }
    if ($Quote -eq "'") {
      if ($Char -eq $Quote) {
        $Quote = [char]0
      }
      continue
    }
    if ($Char -eq '"' -or $Char -eq "'") {
      $Quote = $Char
      continue
    }
    if ($Char -eq '=') {
      return (Get-TomlKeySegments $Line.Substring(0, $Index))
    }
  }
  return $null
}

function Assert-SupportedImage2ConfigHeaders([string[]]$Lines, [string]$ConfigFile) {
  foreach ($Line in $Lines) {
    $IsTable = (Test-TomlTableHeader $Line) -or (Test-TomlArrayTableHeader $Line)
    $Segments = @(Get-TomlHeaderKeySegments $Line)
    if ($IsTable -and $Segments.Count -ge 2 -and $Segments[0] -eq "mcp_servers" -and $Segments[1] -eq "image2" -and -not (Test-Image2ConfigHeader $Line)) {
      throw "unsupported Image2 TOML table header in $ConfigFile"
    }
  }
}

function Assert-SupportedImage2ConfigAssignments([string[]]$Lines) {
  $CurrentTable = @()
  foreach ($Line in $Lines) {
    if ((Test-TomlTableHeader $Line) -or (Test-TomlArrayTableHeader $Line)) {
      $CurrentTable = @(Get-TomlHeaderKeySegments $Line)
      continue
    }
    $Assignment = @(Get-TomlAssignmentKeySegments $Line)
    if ($Assignment.Count -eq 0) {
      continue
    }
    if ($CurrentTable.Count -eq 0 -and $Assignment[0] -ceq "mcp_servers" -and ($Assignment.Count -eq 1 -or $Assignment[1] -ceq "image2")) {
      throw "unsupported conflicting Image2 TOML assignment"
    }
    if ($CurrentTable.Count -eq 1 -and $CurrentTable[0] -ceq "mcp_servers" -and $Assignment[0] -ceq "image2") {
      throw "unsupported conflicting Image2 TOML assignment"
    }
  }
}

function Assert-SupportedImage2Config([string]$ConfigFile) {
  if (-not (Test-Path $ConfigFile)) {
    return
  }
  $Lines = [IO.File]::ReadAllLines($ConfigFile)
  Assert-SupportedImage2ConfigHeaders $Lines $ConfigFile
  Assert-SupportedImage2ConfigAssignments $Lines
}

function Remove-Image2ConfigNamespace([string[]]$Lines) {
  $Output = New-Object System.Collections.Generic.List[string]
  $Skip = $false
  foreach ($Line in $Lines) {
    if (Test-TomlTableHeader $Line) {
      $Skip = Test-Image2ConfigHeader $Line
    } elseif (Test-TomlArrayTableHeader $Line) {
      $Skip = $false
    }
    if (-not $Skip) {
      $Output.Add($Line)
    }
  }
  return $Output.ToArray()
}

function ConvertTo-TomlBasicString([string]$Value) {
  return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Set-Image2CodexConfig([string]$ConfigFile) {
  $Lines = if (Test-Path $ConfigFile) { [IO.File]::ReadAllLines($ConfigFile) } else { @() }
  Assert-SupportedImage2ConfigHeaders $Lines $ConfigFile
  Assert-SupportedImage2ConfigAssignments $Lines
  $Output = New-Object System.Collections.Generic.List[string]
  foreach ($Line in (Remove-Image2ConfigNamespace $Lines)) {
    $Output.Add($Line)
  }
  $Runner = ConvertTo-TomlBasicString (Join-Path $RepoDir "scripts\run-image2-mcp.ps1")
  $Output.Add("")
  $Output.Add("[mcp_servers.image2]")
  $Output.Add('command = "powershell.exe"')
  $RunnerLine = 'args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "' + $Runner + '"]'
  $Output.Add($RunnerLine)
  $Output.Add('startup_timeout_sec = 20')
  $Output.Add('tool_timeout_sec = 600')

  $Temp = "$ConfigFile.tmp.$([Guid]::NewGuid().ToString('N'))"
  $Encoding = New-Object Text.UTF8Encoding($false)
  try {
    [IO.File]::WriteAllLines($Temp, $Output, $Encoding)
    $Generated = [IO.File]::ReadAllText($Temp)
    if (([regex]::Matches($Generated, '(?m)^\[mcp_servers\.image2\]\r?$')).Count -ne 1) {
      throw "generated Codex config does not contain exactly one Image2 root table"
    }
    # The existing Image2 namespace is removed before this static block is
    # appended. Other MCP providers may legitimately configure their own keys.
    if (-not $Generated.Contains($RunnerLine)) {
      throw "generated Codex config runner verification failed"
    }
    Move-FileAtomically $Temp $ConfigFile
  } finally {
    if (Test-Path $Temp) {
      Remove-Item -Force $Temp
    }
  }
}

function Configure-CodexInstall {
  $ConfigDir = Join-Path $HOME ".codex"
  $ConfigFile = Join-Path $ConfigDir "config.toml"
  New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
  if (-not (Test-Path $ConfigFile)) {
    [IO.File]::WriteAllText($ConfigFile, "", (New-Object Text.UTF8Encoding($false)))
  }

  $Existing = [IO.File]::ReadAllText($ConfigFile)
  if ($Existing -match '(?m)^\[mcp_servers\.image2\]' -and -not $ForceConfig) {
    Write-Host "==> Codex MCP config already contains [mcp_servers.image2]; leaving it unchanged: $ConfigFile"
    return
  }
  if ($Existing -match '(?m)^\[mcp_servers\.image2') {
    Write-Host "==> Replacing existing image2 MCP config in $ConfigFile"
  } else {
    Write-Host "==> Adding image2 MCP config to $ConfigFile"
  }
  Set-Image2CodexConfig $ConfigFile
}

function Stop-Image2VerificationProcess([Diagnostics.Process]$Process) {
  if ($Process.HasExited) { return }

  # Process.Kill(true) is unavailable in Windows PowerShell 5.1. taskkill /T
  # also stops the runner's binary and its MCP subprocess before the root exits.
  $TreeKiller = $null
  try {
    $Info = New-Object Diagnostics.ProcessStartInfo
    $Info.FileName = Join-Path $env:SystemRoot "System32\taskkill.exe"
    $Info.Arguments = "/PID $($Process.Id) /T /F"
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    foreach ($KeyName in @("OPENAI_IMAGE_API_KEY", "GEMINI_IMAGE_API_KEY")) {
      $Info.EnvironmentVariables.Remove($KeyName)
    }
    $TreeKiller = [Diagnostics.Process]::Start($Info)
    if (-not $TreeKiller.WaitForExit(5000)) {
      $TreeKiller.Kill()
    }
  } catch {
    # Still terminate the runner if taskkill is unavailable or races with exit.
  } finally {
    if ($null -ne $TreeKiller) { $TreeKiller.Dispose() }
    if (-not $Process.WaitForExit(5000)) {
      $Process.Kill()
      [void]$Process.WaitForExit(5000)
    }
  }
}

function Test-KeyOnlyInstall {
  $Binary = Join-Path $RepoDir "dist\image2-mcp.exe"
  $Runner = Join-Path $RepoDir "scripts\run-image2-mcp.ps1"
  $Config = Join-Path $HOME ".codex\config.toml"
  if (-not (Test-Path $Binary) -or (Get-Item $Binary).Length -eq 0) {
    throw "binary verification failed"
  }
  if (-not (Test-Path $Runner)) {
    throw "runner verification failed"
  }

  $PowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $QuotedRunner = '"' + $Runner.Replace('"', '\"') + '"'
  $Info = New-Object Diagnostics.ProcessStartInfo
  $Info.FileName = $PowerShell
  $Info.Arguments = "-NoProfile -ExecutionPolicy Bypass -File $QuotedRunner --verify-mcp"
  $Info.UseShellExecute = $false
  $Info.CreateNoWindow = $true
  $Info.RedirectStandardInput = $true
  $Info.RedirectStandardOutput = $true
  $Info.RedirectStandardError = $true
  # The runner must load credentials from .env.local; do not pass installer
  # credentials through this child-process environment.
  foreach ($KeyName in @("OPENAI_IMAGE_API_KEY", "GEMINI_IMAGE_API_KEY")) {
    $Info.EnvironmentVariables.Remove($KeyName)
  }
  $Process = New-Object Diagnostics.Process
  $Process.StartInfo = $Info
  $Started = $false
  $Timer = [Diagnostics.Stopwatch]::StartNew()
  try {
    $Started = $Process.Start()
    $Process.StandardInput.Close()
    # Drain both streams concurrently, keeping child diagnostics (and any key)
    # out of console output and temporary files.
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit(20000)) {
      throw "runner MCP verification timed out after 20 seconds"
    }
    $Remaining = [Math]::Max(0, 20000 - [int]$Timer.ElapsedMilliseconds)
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($StdoutTask, $StderrTask), $Remaining)) {
      throw "runner MCP verification timed out after 20 seconds"
    }
    if ($Process.ExitCode -ne 0 -or
        -not (($StdoutTask.Result -split '\r?\n') -ccontains "MCP verification: OK")) {
      throw "runner MCP verification failed"
    }
  } finally {
    try { if ($Started) { Stop-Image2VerificationProcess $Process } } finally { $Process.Dispose() }
  }

  Import-DotEnv (Join-Path $RepoDir ".env.local")
  if ($env:OPENAI_IMAGE_BASE_URL -ne $KeyOnlyBaseUrl -or
      $env:GEMINI_IMAGE_BASE_URL -ne $KeyOnlyBaseUrl -or
      ([string]::IsNullOrWhiteSpace($env:OPENAI_IMAGE_API_KEY) -and
       [string]::IsNullOrWhiteSpace($env:GEMINI_IMAGE_API_KEY))) {
    throw "environment verification failed"
  }
  $ConfigText = [IO.File]::ReadAllText($Config)
  if (([regex]::Matches($ConfigText, '(?m)^\[mcp_servers\.image2\]\r?$')).Count -ne 1) {
    throw "Codex config verification failed"
  }
  $ExpectedRunner = ConvertTo-TomlBasicString $Runner
  if (-not $ConfigText.Contains($ExpectedRunner)) {
    throw "Codex config runner verification failed"
  }
  Write-Host "Verification: OK"
}

function Write-InteractiveEnvironment {
  Write-Host "==> Interactive configuration"
  if ([Console]::IsInputRedirected) {
    Write-Host -NoNewline "OPENAI_IMAGE_BASE_URL [$BaseUrl]: "
    $InputBaseUrl = [Console]::In.ReadLine()
    if ($null -eq $InputBaseUrl) {
      throw "missing base URL input line"
    }
    if ($InputBaseUrl.Length -gt 0 -and [int]$InputBaseUrl[0] -eq 0xFEFF) {
      $InputBaseUrl = $InputBaseUrl.Substring(1)
    }
    Write-Host ""
  } else {
    $InputBaseUrl = Read-Host "OPENAI_IMAGE_BASE_URL [$BaseUrl]"
  }
  if (-not [string]::IsNullOrWhiteSpace($InputBaseUrl)) {
    $script:BaseUrl = $InputBaseUrl
  }

  Read-KeyOnce
  Write-KeyOnlyEnvironment $BaseUrl
  Write-Host "==> Wrote local environment file: $RepoDir\.env.local"
}

function Invoke-WithoutImageCredentials([scriptblock]$Action) {
  $PreviousImageKey = $env:OPENAI_IMAGE_API_KEY
  $PreviousGeminiKey = $env:GEMINI_IMAGE_API_KEY
  try {
    $env:OPENAI_IMAGE_API_KEY = $null
    $env:GEMINI_IMAGE_API_KEY = $null
    & $Action
  } finally {
    $env:OPENAI_IMAGE_API_KEY = $PreviousImageKey
    $env:GEMINI_IMAGE_API_KEY = $PreviousGeminiKey
  }
}

function Invoke-Installer {
  if ($Help) {
    Show-Help
    return
  }

  if ($Offline -and -not $KeyOnly) {
    throw "-Offline requires -KeyOnly"
  }

  if ($KeyOnly) {
    $Conflicts = @($BoundInstallerParameters.Keys | Where-Object { $_ -notin @("KeyOnly", "Offline") })
    if ($Conflicts.Count -gt 0) {
      throw "-KeyOnly cannot be combined with other options: $($Conflicts -join ', ')"
    }
    $script:BaseUrl = $KeyOnlyBaseUrl
    $script:ConfigureCodex = $true
    $script:ForceConfig = $true
    $script:Prebuilt = $true
    $script:SkipTests = $true
    $script:Smoke = $false
    $env:IMAGE2_MCP_REPO = $KeyOnlyRepo
  } elseif ($ForceConfig) {
    $script:ConfigureCodex = $true
  }

  Push-Location $RepoDir
  try {
    if ($Offline) {
      . (Join-Path $RepoDir "scripts\offline-binary.ps1")
      Test-OfflineBinary $RepoDir
    }
    if ($ConfigureCodex) {
      Assert-SupportedImage2Config (Join-Path $HOME ".codex\config.toml")
    }
    if ($KeyOnly) {
      Read-KeyOnce
      Write-KeyOnlyEnvironment
      $env:OPENAI_IMAGE_API_KEY = $script:KeyOnlyApiKey
      $env:OPENAI_IMAGE_BASE_URL = $KeyOnlyBaseUrl
      $env:GEMINI_IMAGE_API_KEY = $script:KeyOnlyGeminiApiKey
      $env:GEMINI_IMAGE_BASE_URL = $KeyOnlyBaseUrl
    } else {
      if ($Interactive) {
        Write-InteractiveEnvironment
      }
      if (Test-Path (Join-Path $RepoDir ".env.local")) {
        Import-DotEnv (Join-Path $RepoDir ".env.local")
      } else {
        Import-DotEnv (Join-Path $RepoDir ".env")
      }
      if ($env:OPENAI_IMAGE_BASE_URL) {
        $script:BaseUrl = $env:OPENAI_IMAGE_BASE_URL
      }
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $RepoDir "dist") | Out-Null
    $GoAvailable = $false
    if (-not $Offline) {
      $GoAvailable = [bool](Get-Command go -ErrorAction SilentlyContinue)
    }
    Invoke-WithoutImageCredentials {
      if ($Offline) {
        Write-Host "==> Using bundled offline binary"
      } elseif ($Prebuilt -or -not $GoAvailable) {
        if (-not $GoAvailable -and -not $SkipTests) {
          Write-Host "==> Go is not installed; skipping source tests and using prebuilt binary"
        }
        Install-Prebuilt
      } else {
        if (-not $SkipTests) {
          Write-Host "==> Running tests"
          go test ./...
          if ($LASTEXITCODE -ne 0) { throw "go test failed" }
        }
        Write-Host "==> Building dist/image2-mcp.exe"
        go build -o ".\dist\image2-mcp.exe" ".\cmd\image2-mcp"
        if ($LASTEXITCODE -ne 0) { throw "go build failed" }
      }
    }

    if ($Smoke) {
      if (-not $GoAvailable) {
        throw "-Smoke currently requires Go because it runs go test"
      }
      if (-not $env:OPENAI_IMAGE_API_KEY -and -not (Test-Path ".env.local")) {
        throw "-Smoke requires OPENAI_IMAGE_API_KEY or .env.local"
      }
      Write-Host "==> Running real image-generation smoke test"
      $PreviousSmoke = $env:RUN_IMAGE2_SMOKE
      $PreviousGeminiKey = $env:GEMINI_IMAGE_API_KEY
      try {
        $env:RUN_IMAGE2_SMOKE = "1"
        $env:GEMINI_IMAGE_API_KEY = $null
        $env:OPENAI_IMAGE_BASE_URL = $BaseUrl
        & go @("test", "./internal/image2", "-run", "TestRealGenerateImage2Smoke", "-count=1", "-v")
        if ($LASTEXITCODE -ne 0) { throw "image generation smoke test failed" }
      } finally {
        $env:RUN_IMAGE2_SMOKE = $PreviousSmoke
        $env:GEMINI_IMAGE_API_KEY = $PreviousGeminiKey
      }
    }

    if ($ConfigureCodex) {
      Configure-CodexInstall
    }
    if ($KeyOnly) {
      Test-KeyOnlyInstall
    }

    Write-Host ""
    Write-Host "Image2 MCP is ready."
    Write-Host "Binary: $RepoDir\dist\image2-mcp.exe"
    Write-Host "Runner: $RepoDir\scripts\run-image2-mcp.ps1"
    Write-Host "Base URL: $BaseUrl"
    if (-not $KeyOnly -and -not (Test-Path ".env.local") -and -not $env:OPENAI_IMAGE_API_KEY) {
      Write-Host "Note: run .\install.ps1 -Interactive to configure independent Image2 and Gemini API keys before using image tools."
    }
  } finally {
    Pop-Location
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  Invoke-Installer
}
