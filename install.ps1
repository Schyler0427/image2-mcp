param(
  [switch]$KeyOnly,
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

function Show-Help {
  @"
Usage: powershell -ExecutionPolicy Bypass -File .\install.ps1 [options]

Install and optionally configure the Image2 MCP server for Codex on Windows.

Options:
  -KeyOnly          Prompt once for an API key and install the fixed Codex configuration.
  -Interactive      Prompt for base URL and API key, then write .env.local.
  -ConfigureCodex   Append an image2 MCP server block to ~/.codex/config.toml.
  -ForceConfig      Replace existing [mcp_servers.image2] config block.
  -BaseUrl URL      Set OPENAI_IMAGE_BASE_URL in .env.local or Codex config.
  -Prebuilt         Download a GitHub Release binary even when Go is installed.
  -SkipTests        Build without running go test ./...
  -Smoke            Run a real image-generation smoke test after build.
  -Help             Show this help.

Environment:
  OPENAI_IMAGE_API_KEY   Required by Codex at runtime, and required for -Smoke.
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
  $Security = New-Object System.Security.AccessControl.FileSecurity
  $CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $SystemSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-18")
  $AdminSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")
  $Security.SetOwner($CurrentSid)
  $Security.SetAccessRuleProtection($true, $false)
  foreach ($Sid in @($CurrentSid, $SystemSid, $AdminSid)) {
    $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
      $Sid,
      [System.Security.AccessControl.FileSystemRights]::FullControl,
      [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$Security.AddAccessRule($Rule)
  }
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

function Write-KeyOnlyEnvironment {
  $Target = Join-Path $RepoDir ".env.local"
  $Temp = Join-Path $RepoDir (".env.local.tmp." + [Guid]::NewGuid().ToString("N"))
  $Encoding = New-Object Text.UTF8Encoding($false)
  try {
    $Lines = @(
      "OPENAI_IMAGE_BASE_URL=$(ConvertTo-DotEnvValue $KeyOnlyBaseUrl)",
      "OPENAI_IMAGE_API_KEY=$(ConvertTo-DotEnvValue $script:KeyOnlyApiKey)"
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

function Read-KeyOnce {
  $InputIsRedirected = [Console]::IsInputRedirected
  if ($InputIsRedirected) {
    Write-Host -NoNewline "OPENAI_IMAGE_API_KEY: "
    $Value = [Console]::In.ReadLine()
    Write-Host ""
  } else {
    $Secret = Read-Host "OPENAI_IMAGE_API_KEY" -AsSecureString
    $Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
      $Value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
    }
  }

  if ($InputIsRedirected -and $Value.Length -gt 0 -and [int]$Value[0] -eq 0xFEFF) {
    $Value = $Value.Substring(1)
  }
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "API Key cannot be blank"
  }
  if ($Value.Contains("`r") -or $Value.Contains("`n") -or $Value.Contains([char]0)) {
    throw "API Key must be one line and cannot contain NUL"
  }
  $script:KeyOnlyApiKey = $Value
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
  $Url = "https://github.com/${Repo}/releases/latest/download/${Asset}"
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
    if ($env:IMAGE2_MCP_TEST_RELEASE_ZIP) {
      Copy-Item $env:IMAGE2_MCP_TEST_RELEASE_ZIP $ZipPath
    } else {
      Invoke-WebRequest -Uri $Url -OutFile $ZipPath
    }
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force
    if (-not (Test-Path $StagedBinary) -or (Get-Item $StagedBinary).Length -eq 0) {
      throw "prebuilt archive does not contain a non-empty image2-mcp.exe"
    }
    Move-FileAtomically $StagedBinary $TargetBinary
  } finally {
    if (Test-Path $TempDir) {
      Remove-Item -Recurse -Force $TempDir
    }
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

  $Text = $Match.Groups['Body'].Value
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

function Assert-SupportedImage2ConfigHeaders([string[]]$Lines, [string]$ConfigFile) {
  foreach ($Line in $Lines) {
    $IsTable = (Test-TomlTableHeader $Line) -or (Test-TomlArrayTableHeader $Line)
    $Segments = @(Get-TomlHeaderKeySegments $Line)
    if ($IsTable -and $Segments.Count -ge 2 -and $Segments[0] -eq "mcp_servers" -and $Segments[1] -eq "image2" -and -not (Test-Image2ConfigHeader $Line)) {
      throw "unsupported Image2 TOML table header in $ConfigFile"
    }
  }
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

  $Temp = "$ConfigFile.tmp.$([Guid]::NewGuid().ToString('N'))"
  $Encoding = New-Object Text.UTF8Encoding($false)
  try {
    [IO.File]::WriteAllLines($Temp, $Output, $Encoding)
    $Generated = [IO.File]::ReadAllText($Temp)
    if (([regex]::Matches($Generated, '(?m)^\[mcp_servers\.image2\]\r?$')).Count -ne 1) {
      throw "generated Codex config does not contain exactly one Image2 root table"
    }
    if ($Generated.Contains("OPENAI_IMAGE_API_KEY")) {
      throw "generated Codex config contains a forbidden API Key setting"
    }
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
  $EmptyInput = Join-Path ([IO.Path]::GetTempPath()) ("image2-mcp-stdin-" + [Guid]::NewGuid().ToString("N"))
  try {
    [IO.File]::WriteAllText($EmptyInput, "", (New-Object Text.UTF8Encoding($false)))
    $Process = Start-Process -FilePath $PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $QuotedRunner" -RedirectStandardInput $EmptyInput -NoNewWindow -PassThru -Wait
    if ($Process.ExitCode -ne 0) {
      throw "runner startup verification failed"
    }
  } finally {
    if (Test-Path $EmptyInput) {
      Remove-Item -Force $EmptyInput
    }
  }

  Import-DotEnv (Join-Path $RepoDir ".env.local")
  if ($env:OPENAI_IMAGE_BASE_URL -ne $KeyOnlyBaseUrl -or [string]::IsNullOrWhiteSpace($env:OPENAI_IMAGE_API_KEY)) {
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
  if ($ConfigText.Contains("OPENAI_IMAGE_API_KEY")) {
    throw "Codex config contains a forbidden API Key setting"
  }
  Write-Host "Verification: OK"
}

function Write-InteractiveEnvironment {
  Write-Host "==> Interactive configuration"
  $InputBaseUrl = Read-Host "OPENAI_IMAGE_BASE_URL [$BaseUrl]"
  if (-not [string]::IsNullOrWhiteSpace($InputBaseUrl)) {
    $script:BaseUrl = $InputBaseUrl
  }

  if ($env:OPENAI_IMAGE_API_KEY) {
    $SaveCurrent = Read-Host "OPENAI_IMAGE_API_KEY is already set in this shell. Save it to .env.local? [y/N]"
    $ApiKey = if ($SaveCurrent -match '^[Yy]$') { $env:OPENAI_IMAGE_API_KEY } else { "" }
  } else {
    $Secret = Read-Host "OPENAI_IMAGE_API_KEY" -AsSecureString
    $Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
      $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
    }
  }

  $Lines = @("OPENAI_IMAGE_BASE_URL=$(ConvertTo-DotEnvValue $BaseUrl)")
  if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $Lines += "OPENAI_IMAGE_API_KEY=$(ConvertTo-DotEnvValue $ApiKey)"
  }
  [IO.File]::WriteAllLines((Join-Path $RepoDir ".env.local"), $Lines, (New-Object Text.UTF8Encoding($false)))
  Write-Host "==> Wrote local environment file: $RepoDir\.env.local"
}

function Invoke-Installer {
  if ($Help) {
    Show-Help
    return
  }

  if ($KeyOnly) {
    $Conflicts = @($BoundInstallerParameters.Keys | Where-Object { $_ -notin @("KeyOnly") })
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
    if ($KeyOnly) {
      Read-KeyOnce
      Write-KeyOnlyEnvironment
      $env:OPENAI_IMAGE_BASE_URL = $KeyOnlyBaseUrl
      $env:OPENAI_IMAGE_API_KEY = $script:KeyOnlyApiKey
    } else {
      if ($Interactive) {
        Write-InteractiveEnvironment
      }
      Import-DotEnv (Join-Path $RepoDir ".env.local")
      Import-DotEnv (Join-Path $RepoDir ".env")
      if ($env:OPENAI_IMAGE_BASE_URL) {
        $script:BaseUrl = $env:OPENAI_IMAGE_BASE_URL
      }
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $RepoDir "dist") | Out-Null
    $GoAvailable = [bool](Get-Command go -ErrorAction SilentlyContinue)
    if ($Prebuilt -or -not $GoAvailable) {
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

    if ($Smoke) {
      if (-not $GoAvailable) {
        throw "-Smoke currently requires Go because it runs go test"
      }
      if (-not $env:OPENAI_IMAGE_API_KEY -and -not (Test-Path ".env.local")) {
        throw "-Smoke requires OPENAI_IMAGE_API_KEY or .env.local"
      }
      Write-Host "==> Running real image-generation smoke test"
      $env:RUN_IMAGE2_SMOKE = "1"
      $env:OPENAI_IMAGE_BASE_URL = $BaseUrl
      & go @("test", "./internal/image2", "-run", "TestRealGenerateImage2Smoke", "-count=1", "-v")
      if ($LASTEXITCODE -ne 0) { throw "image generation smoke test failed" }
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
      Write-Host "Note: set OPENAI_IMAGE_API_KEY or run .\install.ps1 -Interactive before Codex uses the MCP server."
    }
  } finally {
    Pop-Location
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  Invoke-Installer
}
