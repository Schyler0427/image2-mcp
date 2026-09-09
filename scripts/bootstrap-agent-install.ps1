function Test-AgentBootstrapReparsePoint([IO.FileSystemInfo]$Item) {
  return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Enable-Image2Tls12 {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Get-AgentBootstrapFullPath([string]$Path) {
  $FullPath = [IO.Path]::GetFullPath($Path)
  $Root = [IO.Path]::GetPathRoot($FullPath)
  if ($FullPath.Length -gt $Root.Length) {
    return $FullPath.TrimEnd([char[]]@('\', '/'))
  }
  return $FullPath
}

function New-AgentBootstrapDirectory([string]$Parent, [string]$Prefix) {
  for ($Attempt = 0; $Attempt -lt 10; $Attempt++) {
    $Path = Join-Path $Parent ($Prefix + [Guid]::NewGuid().ToString("N"))
    if (-not (Test-Path -LiteralPath $Path)) {
      [IO.Directory]::CreateDirectory($Path) | Out-Null
      return $Path
    }
  }
  throw "could not allocate a transaction directory"
}

function Assert-AgentBootstrapPlainFile([string]$Path, [string]$Description) {
  $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if ($Item.PSIsContainer -or (Test-AgentBootstrapReparsePoint $Item)) {
    throw "$Description is not a regular file"
  }
}

function Assert-AgentBootstrapPlainDirectory([string]$Path, [string]$Description) {
  $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (-not $Item.PSIsContainer -or (Test-AgentBootstrapReparsePoint $Item)) {
    throw "$Description is not a regular directory"
  }
}

function Assert-AgentBootstrapRelease($Release, [string[]]$RequiredAssets) {
  if ($null -eq $Release -or $Release.tag_name -cne "v0.3.0") {
    throw "public Release gate returned the wrong tag"
  }
  if ($Release.draft -isnot [bool] -or $Release.draft) {
    throw "public v0.3.0 Release must not be a draft"
  }
  if ($Release.prerelease -isnot [bool] -or $Release.prerelease) {
    throw "public v0.3.0 Release must not be a prerelease"
  }

  $AssetNames = @()
  foreach ($Asset in @($Release.assets)) {
    if ($null -ne $Asset -and $Asset.name -is [string]) {
      $AssetNames += $Asset.name
    }
  }
  foreach ($Name in $RequiredAssets) {
    if (-not ($AssetNames -ccontains $Name)) {
      throw "public v0.3.0 Release is missing required asset: $Name"
    }
  }
}

function Assert-AgentBootstrapReleasePage(
  [string]$PageContent,
  [string]$AssetsContent,
  [string[]]$RequiredAssets
) {
  $ExpectedTitle = '<title>Release v0.3.0 ' + [char]0x00B7 + ' Schyler0427/image2-mcp ' + [char]0x00B7 + ' GitHub</title>'
  if ([string]::IsNullOrEmpty($PageContent) -or
      -not $PageContent.Contains($ExpectedTitle)) {
    throw "public Release page returned the wrong tag"
  }
  if ([regex]::IsMatch($PageContent, '(?i)>Pre-release<')) {
    throw "public v0.3.0 Release must not be a prerelease"
  }
  if ([string]::IsNullOrEmpty($AssetsContent)) {
    throw "public Release asset page was empty"
  }
  foreach ($Name in $RequiredAssets) {
    if (-not $AssetsContent.Contains("/releases/download/v0.3.0/$Name")) {
      throw "public v0.3.0 Release is missing required asset: $Name"
    }
  }
}

function Invoke-AgentBootstrapMetadata([string]$Uri) {
  return Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri $Uri
}

function Assert-AgentBootstrapExistingTarget(
  [string]$Target,
  [string]$RepositoryUrl,
  [string]$RepositorySlug
) {
  $TargetItem = Get-Item -LiteralPath $Target -Force -ErrorAction Stop
  if (-not $TargetItem.PSIsContainer) {
    throw "managed target is not a directory"
  }
  if (Test-AgentBootstrapReparsePoint $TargetItem) {
    throw "managed target must not be a reparse point"
  }

  Assert-AgentBootstrapPlainFile (Join-Path $Target "install.sh") "existing target install.sh"
  Assert-AgentBootstrapPlainFile (Join-Path $Target "install.ps1") "existing target install.ps1"
  Assert-AgentBootstrapPlainFile (Join-Path $Target "go.mod") "existing target go.mod"
  Assert-AgentBootstrapPlainDirectory (Join-Path $Target "scripts") "existing target scripts directory"

  $GitPath = Join-Path $Target ".git"
  $GitEntry = @(Get-ChildItem -LiteralPath $Target -Force -ErrorAction Stop | Where-Object {
    $_.Name -ceq ".git"
  } | Select-Object -First 1)[0]
  if ($null -ne $GitEntry) {
    if (Test-AgentBootstrapReparsePoint $GitEntry) {
      throw "existing Git metadata is not a regular directory"
    }
    Assert-AgentBootstrapPlainDirectory $GitPath "existing Git metadata"
    $GitConfig = Join-Path $GitPath "config"
    Assert-AgentBootstrapPlainFile $GitConfig "existing Git config"
    $GitConfigWorktreeEntry = @(Get-ChildItem -LiteralPath $GitPath -Force -ErrorAction Stop | Where-Object {
      $_.Name -ceq "config.worktree"
    } | Select-Object -First 1)[0]
    if ($null -ne $GitConfigWorktreeEntry) {
      throw "existing Git target has unsupported ownership configuration"
    }
    $InOrigin = $false
    $RemoteCount = 0
    $Remote = $null
    $Section = $null
    $BareCount = 0
    $BareValue = $null
    foreach ($Line in [IO.File]::ReadAllLines($GitConfig)) {
      $Trimmed = $Line.TrimStart()
      if ($Trimmed.StartsWith("[")) {
        if ($Trimmed -notmatch '^\[([^\]]+)\]$') {
          throw "existing Git target has unsupported ownership configuration"
        }
        $Section = $Matches[1].ToLowerInvariant()
        if ($Section.StartsWith("include")) {
          throw "existing Git target has unsupported ownership configuration"
        }
        $InOrigin = ($Trimmed -ceq '[remote "origin"]')
        continue
      }
      if ([string]::IsNullOrWhiteSpace($Trimmed) -or $Trimmed.StartsWith("#") -or $Trimmed.StartsWith(";")) {
        continue
      }
      if ($Trimmed -notmatch '^([^\s=]+)(?:\s*=\s*(.*))?$') {
        continue
      }
      $Key = $Matches[1].ToLowerInvariant()
      $Value = if ($Trimmed.Contains("=")) { $Matches[2] } else { $null }
      if ($Section -ceq "core") {
        if ($Key -ceq "worktree") {
          throw "existing Git target has unsupported ownership configuration"
        }
        if ($Key -ceq "bare") {
          $BareCount++
          $BareValue = if ($null -eq $Value) { $null } else { $Value.Trim().ToLowerInvariant() }
        }
      }
      if ($Section -ceq "extensions" -and $Key -ceq "worktreeconfig") {
        throw "existing Git target has unsupported ownership configuration"
      }
      if ($InOrigin -and $Key -ceq "url" -and $Trimmed -match '^url\s*=\s*(.*)$') {
        $Remote = $Matches[1]
        $RemoteCount++
      }
    }
    if ($BareCount -gt 1 -or ($BareCount -eq 1 -and $BareValue -cne "false")) {
      throw "existing Git target has unsupported ownership configuration"
    }
    if ($RemoteCount -ne 1) {
      throw "existing Git target has no unique origin remote"
    }
    if ($Remote -cne $RepositoryUrl) {
      throw "existing Git target origin does not match the fixed repository"
    }
    $GitCommand = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
    $GitUsable = $false
    if ($null -ne $GitCommand) {
      try {
        & $GitCommand.Source --version | Out-Null
        $GitUsable = ($LASTEXITCODE -eq 0)
      } catch {
        $GitUsable = $false
      }
    }
    if ($GitUsable) {
      try {
        $GitTopLevelOutput = @(& $GitCommand.Source -C $Target rev-parse --show-toplevel)
        if ($LASTEXITCODE -ne 0 -or $GitTopLevelOutput.Count -ne 1) {
          throw "rev-parse did not return one top-level path"
        }
        $TargetFullPath = Get-AgentBootstrapFullPath $Target
        $GitTopLevelFullPath = Get-AgentBootstrapFullPath ([string]$GitTopLevelOutput[0])
      } catch {
        throw "existing Git target ownership cannot be proven"
      }
      if ($GitTopLevelFullPath -ine $TargetFullPath) {
        throw "existing Git target ownership cannot be proven"
      }
    }
    return
  }

  $MarkerPath = Join-Path $Target ".image2-mcp-managed"
  Assert-AgentBootstrapPlainFile $MarkerPath "existing target managed marker"
  $MarkerBytes = [IO.File]::ReadAllBytes($MarkerPath)
  $ExpectedMarkerBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($RepositorySlug)
  if ($MarkerBytes.Length -ne $ExpectedMarkerBytes.Length) {
    throw "existing archive target marker does not match the fixed repository"
  }
  for ($Index = 0; $Index -lt $ExpectedMarkerBytes.Length; $Index++) {
    if ($MarkerBytes[$Index] -ne $ExpectedMarkerBytes[$Index]) {
      throw "existing archive target marker does not match the fixed repository"
    }
  }
}

function Assert-AgentBootstrapZip(
  [string]$ArchivePath,
  [string]$SourceRoot,
  [string[]]$RequiredPaths
) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
  $Entries = @{}
  $Zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    if ($Zip.Entries.Count -eq 0) {
      throw "source ZIP is empty"
    }

    foreach ($Entry in $Zip.Entries) {
      $Name = [string]$Entry.FullName
      if ([string]::IsNullOrEmpty($Name)) {
        throw "source ZIP contains an empty path"
      }
      foreach ($Character in $Name.ToCharArray()) {
        if ([char]::IsControl($Character)) {
          throw "source ZIP contains a control character in a path"
        }
      }
      if ($Name.StartsWith("/") -or $Name.StartsWith("\") -or
          [IO.Path]::IsPathRooted($Name) -or $Name -match '^[A-Za-z]:') {
        throw "source ZIP contains an absolute or rooted path"
      }

      $Normalized = $Name.Replace('\', '/')
      $IsTrailingDirectory = $Normalized.EndsWith("/")
      $Canonical = $Normalized.TrimEnd('/')
      if ([string]::IsNullOrEmpty($Canonical)) {
        throw "source ZIP contains an empty canonical path"
      }
      $Segments = $Canonical.Split('/')
      foreach ($Segment in $Segments) {
        if ([string]::IsNullOrEmpty($Segment) -or $Segment -eq "." -or
            $Segment -eq ".." -or $Segment.Contains(":")) {
          throw "source ZIP contains a traversal or ambiguous path"
        }
      }
      if ($Segments[0] -cne $SourceRoot) {
        throw "source ZIP contains a path outside the expected root"
      }

      $ExternalAttributes = [int]$Entry.ExternalAttributes
      $DosAttributes = $ExternalAttributes -band 0xFFFF
      $UnixType = ($ExternalAttributes -shr 16) -band 0xF000
      if (($DosAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0 -or
          $UnixType -eq 0xA000) {
        throw "source ZIP contains a symlink or reparse entry"
      }
      if ($UnixType -ne 0 -and $UnixType -ne 0x4000 -and $UnixType -ne 0x8000) {
        throw "source ZIP contains an unsupported entry type"
      }
      $IsDirectory = $IsTrailingDirectory -or $Entry.Name.Length -eq 0 -or
        (($DosAttributes -band [int][IO.FileAttributes]::Directory) -ne 0) -or
        $UnixType -eq 0x4000

      if ($Entries.ContainsKey($Canonical)) {
        throw "source ZIP contains a case-insensitive duplicate canonical path"
      }
      $Entries[$Canonical] = [PSCustomObject]@{
        Canonical = $Canonical
        IsDirectory = [bool]$IsDirectory
      }
    }
  } finally {
    $Zip.Dispose()
  }

  foreach ($Info in $Entries.Values) {
    $Parent = $Info.Canonical
    while ($Parent.Contains("/")) {
      $Parent = $Parent.Substring(0, $Parent.LastIndexOf("/"))
      if ($Entries.ContainsKey($Parent) -and -not $Entries[$Parent].IsDirectory) {
        throw "source ZIP contains a file/directory prefix collision"
      }
    }
  }

  foreach ($Required in $RequiredPaths) {
    if (-not $Entries.ContainsKey($Required) -or
        $Entries[$Required].Canonical -cne $Required -or
        $Entries[$Required].IsDirectory) {
      throw "source ZIP is missing required repository file: $Required"
    }
  }
}

function Assert-AgentBootstrapExtractedSource(
  [string]$StagePath,
  [string[]]$RequiredRelativePaths
) {
  Assert-AgentBootstrapPlainDirectory $StagePath "staged source root"
  $StageItem = Get-Item -LiteralPath $StagePath -Force
  $StageFullPath = Get-AgentBootstrapFullPath $StageItem.FullName
  $StagePrefix = $StageFullPath + [IO.Path]::DirectorySeparatorChar

  $Pending = New-Object System.Collections.Stack
  $Pending.Push([IO.DirectoryInfo]$StageItem)
  while ($Pending.Count -gt 0) {
    $Directory = [IO.DirectoryInfo]$Pending.Pop()
    foreach ($Item in $Directory.GetFileSystemInfos()) {
      $FullPath = [IO.Path]::GetFullPath($Item.FullName)
      if (-not $FullPath.StartsWith($StagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "extracted source escaped the staging root"
      }
      if (Test-AgentBootstrapReparsePoint $Item) {
        throw "extracted source contains a reparse point"
      }
      if ($Item -is [IO.DirectoryInfo]) {
        $Pending.Push([IO.DirectoryInfo]$Item)
      }
    }
  }

  foreach ($RelativePath in $RequiredRelativePaths) {
    $RequiredPath = Join-Path $StagePath ($RelativePath.Replace('/', '\'))
    Assert-AgentBootstrapPlainFile $RequiredPath "staged source $RelativePath"
    $RequiredFullPath = [IO.Path]::GetFullPath($RequiredPath)
    if (-not $RequiredFullPath.StartsWith($StagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "required staged source path escaped the staging root"
    }
  }
}

function New-AgentBootstrapConfigSnapshot([string]$ConfigPath, [string]$SnapshotPath) {
  $State = [PSCustomObject]@{
    Path = $ConfigPath
    Existed = $false
    Snapshot = $SnapshotPath
    Attributes = [IO.FileAttributes]::Normal
    CreationTimeUtc = [DateTime]::MinValue
    LastWriteTimeUtc = [DateTime]::MinValue
  }
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    return $State
  }

  $Item = Get-Item -LiteralPath $ConfigPath -Force
  if ($Item.PSIsContainer -or (Test-AgentBootstrapReparsePoint $Item)) {
    throw "Codex config path is not a regular file"
  }
  [IO.File]::Copy($ConfigPath, $SnapshotPath, $false)
  $State.Existed = $true
  $State.Attributes = $Item.Attributes
  $State.CreationTimeUtc = $Item.CreationTimeUtc
  $State.LastWriteTimeUtc = $Item.LastWriteTimeUtc
  return $State
}

function Restore-AgentBootstrapConfig($State) {
  if ($null -eq $State) {
    return
  }
  if ($State.Existed) {
    $Parent = Split-Path -Parent $State.Path
    [IO.Directory]::CreateDirectory($Parent) | Out-Null
    if ([IO.File]::Exists($State.Path)) {
      [IO.File]::SetAttributes($State.Path, [IO.FileAttributes]::Normal)
    } elseif (Test-Path -LiteralPath $State.Path) {
      throw "cannot restore Codex config over a non-file path"
    }
    [IO.File]::Copy($State.Snapshot, $State.Path, $true)
    [IO.File]::SetCreationTimeUtc($State.Path, $State.CreationTimeUtc)
    [IO.File]::SetLastWriteTimeUtc($State.Path, $State.LastWriteTimeUtc)
    [IO.File]::SetAttributes($State.Path, $State.Attributes)
    return
  }

  if ([IO.File]::Exists($State.Path)) {
    [IO.File]::SetAttributes($State.Path, [IO.FileAttributes]::Normal)
    [IO.File]::Delete($State.Path)
  } elseif (Test-Path -LiteralPath $State.Path) {
    throw "cannot restore absent Codex config over a non-file path"
  }
}

function Invoke-AgentBootstrapInstaller(
  [string]$InstallerPath,
  [string]$RepositorySlug
) {
  $PowerShell = Get-Command powershell.exe -CommandType Application -ErrorAction Stop
  $PreviousRepository = [Environment]::GetEnvironmentVariable("IMAGE2_MCP_REPO", "Process")
  try {
    [Environment]::SetEnvironmentVariable("IMAGE2_MCP_REPO", $RepositorySlug, "Process")
    Push-Location (Split-Path -Parent $InstallerPath)
    try {
      & $PowerShell.Source -NoProfile -ExecutionPolicy Bypass -File $InstallerPath -KeyOnly
      $InstallerExitCode = $LASTEXITCODE
    } finally {
      Pop-Location
    }
  } finally {
    [Environment]::SetEnvironmentVariable("IMAGE2_MCP_REPO", $PreviousRepository, "Process")
  }
  if ($InstallerExitCode -ne 0) {
    throw "key-only installer failed; the previous target will be restored"
  }
}

function Write-AgentBootstrapRetainedEvidence(
  [string]$TransactionPath,
  [string]$BackupRoot
) {
  if (Test-Path -LiteralPath $TransactionPath) {
    Write-Host "Retained transaction evidence: $TransactionPath"
    $FailedTarget = Join-Path $TransactionPath "failed-target"
    if (Test-Path -LiteralPath $FailedTarget) {
      Write-Host "Retained failed target evidence: $FailedTarget"
    }
  }
  if ($BackupRoot -and (Test-Path -LiteralPath $BackupRoot)) {
    $Previous = Join-Path $BackupRoot "previous"
    if (Test-Path -LiteralPath $Previous) {
      Write-Host "Previous installation retained at: $Previous"
    } else {
      Write-Host "Retained backup evidence: $BackupRoot"
    }
  }
}

function Restore-AgentBootstrapTransaction(
  [string]$Target,
  [string]$TransactionPath,
  [string]$StagePath,
  [string]$BackupRoot,
  [bool]$Repeat,
  [bool]$OldMoveIntent,
  [bool]$NewMoveIntent,
  $ConfigState
) {
  $Problems = New-Object 'System.Collections.Generic.List[string]'
  $Previous = if ($BackupRoot) { Join-Path $BackupRoot "previous" } else { $null }
  $StageExists = $StagePath -and (Test-Path -LiteralPath $StagePath)
  $TargetExists = Test-Path -LiteralPath $Target
  $PreviousExists = $Previous -and (Test-Path -LiteralPath $Previous)
  $NewMoved = $NewMoveIntent -and -not $StageExists -and $TargetExists

  if ($NewMoved) {
    try {
      $FailedTarget = Join-Path $TransactionPath "failed-target"
      if (Test-Path -LiteralPath $FailedTarget) {
        throw "failed-target evidence path already exists"
      }
      [IO.Directory]::Move($Target, $FailedTarget)
    } catch {
      $Problems.Add("could not deactivate failed target: $($_.Exception.Message)")
    }
  } elseif ($NewMoveIntent -and -not $StageExists -and -not $TargetExists) {
    $Problems.Add("could not locate the staged or activated target")
  }

  if ($Repeat -and $PreviousExists) {
    try {
      if (Test-Path -LiteralPath $Target) {
        throw "failed target still occupies the managed path"
      }
      [IO.Directory]::Move($Previous, $Target)
    } catch {
      $Problems.Add("could not restore previous target: $($_.Exception.Message)")
    }
  } elseif ($Repeat -and $OldMoveIntent -and -not (Test-Path -LiteralPath $Target)) {
    $Problems.Add("could not locate the previous target")
  }

  if ($BackupRoot -and (Test-Path -LiteralPath $BackupRoot) -and
      -not (Test-Path -LiteralPath $Previous)) {
    try {
      [IO.Directory]::Delete($BackupRoot, $false)
    } catch {
      $Problems.Add("could not remove failed backup directory: $($_.Exception.Message)")
    }
  }
  try {
    Restore-AgentBootstrapConfig $ConfigState
  } catch {
    $Problems.Add("could not restore Codex config: $($_.Exception.Message)")
  }
  if ($Problems.Count -gt 0) {
    throw ($Problems -join "; ")
  }
}

function Invoke-AgentBootstrap {
  $ErrorActionPreference = "Stop"
  $RepositoryUrl = "https://github.com/Schyler0427/image2-mcp.git"
  $RepositorySlug = "Schyler0427/image2-mcp"
  $ReleaseApi = "https://api.github.com/repos/Schyler0427/image2-mcp/releases/tags/v0.3.0"
  $ReleasePageUrl = "https://github.com/Schyler0427/image2-mcp/releases/tag/v0.3.0"
  $ReleaseAssetsPageUrl = "https://github.com/Schyler0427/image2-mcp/releases/expanded_assets/v0.3.0"
  $SourceUrl = "https://github.com/Schyler0427/image2-mcp/archive/refs/tags/v0.3.0.zip"
  $SourceRoot = "image2-mcp-0.3.0"
  $BaseUrl = "https://api.schyler.top"
  $RequiredAssets = @(
    "image2-mcp_darwin_arm64.tar.gz",
    "image2-mcp_darwin_amd64.tar.gz",
    "image2-mcp_linux_arm64.tar.gz",
    "image2-mcp_linux_amd64.tar.gz",
    "image2-mcp_windows_arm64.zip",
    "image2-mcp_windows_amd64.zip"
  )
  $RequiredArchivePaths = @(
    "$SourceRoot/install.sh",
    "$SourceRoot/install.ps1",
    "$SourceRoot/go.mod",
    "$SourceRoot/scripts/run-image2-mcp.ps1"
  )
  $RequiredStagePaths = @(
    "install.sh",
    "install.ps1",
    "go.mod",
    "scripts/run-image2-mcp.ps1"
  )

  if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw "LOCALAPPDATA is required"
  }
  if ([string]::IsNullOrWhiteSpace($HOME)) {
    throw "HOME is required"
  }

  $HomePath = [string]$HOME
  $Parent = $env:LOCALAPPDATA
  $Target = Join-Path $Parent "image2-mcp"
  $ConfigPath = Join-Path (Join-Path $HomePath ".codex") "config.toml"
  [IO.Directory]::CreateDirectory($Parent) | Out-Null
  $TransactionPath = New-AgentBootstrapDirectory $Parent ".image2-mcp-bootstrap."
  $BackupRoot = $null
  $StagePath = $null
  $OldMoveIntent = $false
  $NewMoveIntent = $false
  $ConfigState = $null
  $Repeat = $false
  $RetainTransaction = $false

  try {
    Enable-Image2Tls12
    Write-Host "Checking public Release..."
    try {
      $ReleasePage = Invoke-AgentBootstrapMetadata $ReleasePageUrl
      $ReleaseAssetsPage = Invoke-AgentBootstrapMetadata $ReleaseAssetsPageUrl
      Assert-AgentBootstrapReleasePage $ReleasePage.Content $ReleaseAssetsPage.Content $RequiredAssets
    } catch {
      try {
        $Release = Invoke-RestMethod -UseBasicParsing -TimeoutSec 15 -Uri $ReleaseApi
        Assert-AgentBootstrapRelease $Release $RequiredAssets
      } catch {
        throw "public v0.3.0 Release gate failed; public pages and GitHub API did not pass"
      }
    }

    $ExistingTarget = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if ($null -ne $ExistingTarget) {
      Assert-AgentBootstrapExistingTarget $Target $RepositoryUrl $RepositorySlug
      $Repeat = $true
    }

    $ArchivePath = Join-Path $TransactionPath "source.zip"
    Write-Host "Downloading source package..."
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $SourceUrl -OutFile $ArchivePath
    Assert-AgentBootstrapZip $ArchivePath $SourceRoot $RequiredArchivePaths
    Write-Host "Preparing installation..."

    $ExtractPath = Join-Path $TransactionPath "extract"
    [IO.Directory]::CreateDirectory($ExtractPath) | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $ExtractPath)
    $StagePath = Join-Path $ExtractPath $SourceRoot
    Assert-AgentBootstrapExtractedSource $StagePath $RequiredStagePaths
    [IO.File]::WriteAllText(
      (Join-Path $StagePath ".image2-mcp-managed"),
      $RepositorySlug,
      (New-Object Text.UTF8Encoding($false))
    )

    $ConfigState = New-AgentBootstrapConfigSnapshot $ConfigPath (Join-Path $TransactionPath "config.toml.before")
    if ($Repeat) {
      $BackupRoot = New-AgentBootstrapDirectory $Parent "image2-mcp.backup."
      $OldMoveIntent = $true
      [IO.Directory]::Move($Target, (Join-Path $BackupRoot "previous"))
    }
    $NewMoveIntent = $true
    [IO.Directory]::Move($StagePath, $Target)

    Write-Host "Installing platform binary..."
    Invoke-AgentBootstrapInstaller (Join-Path $Target "install.ps1") $RepositorySlug
    Write-Host "Verifying local installation..."
    Write-Host "Verification: OK"
    Write-Host "Install directory: $Target"
    Write-Host "Binary: $(Join-Path $Target 'dist\image2-mcp.exe')"
    Write-Host "Runner: $(Join-Path $Target 'scripts\run-image2-mcp.ps1')"
    Write-Host "Codex config: $ConfigPath"
    Write-Host "Base URL: $BaseUrl"
    Write-Host "API Key configured (not displayed)."
    if ($Repeat) {
      Write-Host "Previous installation retained at: $(Join-Path $BackupRoot 'previous')"
      Write-Host "Previous local and customer content is not active in the refreshed target."
    }
  } catch {
    $OriginalMessage = $_.Exception.Message
    try {
      Restore-AgentBootstrapTransaction `
        -Target $Target -TransactionPath $TransactionPath -StagePath $StagePath `
        -BackupRoot $BackupRoot -Repeat $Repeat -OldMoveIntent $OldMoveIntent `
        -NewMoveIntent $NewMoveIntent -ConfigState $ConfigState
    } catch {
      $RetainTransaction = $true
      Write-AgentBootstrapRetainedEvidence $TransactionPath $BackupRoot
      throw "bootstrap failed: $OriginalMessage; rollback failed: $($_.Exception.Message)"
    }
    throw "bootstrap failed: $OriginalMessage"
  } finally {
    if (-not $RetainTransaction -and (Test-Path -LiteralPath $TransactionPath)) {
      try {
        Remove-Item -LiteralPath $TransactionPath -Recurse -Force -ErrorAction Stop
      } catch {
        $RetainTransaction = $true
        Write-Host "Transaction cleanup failed; evidence retained."
        Write-AgentBootstrapRetainedEvidence $TransactionPath $BackupRoot
        throw "bootstrap cleanup failed: $($_.Exception.Message)"
      }
    }
  }
}

if ($MyInvocation.InvocationName -ne ".") {
  Invoke-AgentBootstrap
}
