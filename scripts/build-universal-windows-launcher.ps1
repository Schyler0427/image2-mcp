[CmdletBinding()]
param(
  [string]$Output = (Join-Path $PSScriptRoot '..\dist\universal-windows-launcher'),
  [string]$Version = ''
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $Root
$VersionMatch = [regex]::Match([IO.File]::ReadAllText((Join-Path $Root 'cmd\image2-mcp\main.go')), '(?m)^const serverVersion = "([^"\r\n]+)"\r?$')
if (-not $VersionMatch.Success) { throw 'could not read serverVersion' }
$ExpectedVersion = $VersionMatch.Groups[1].Value
if ([string]::IsNullOrEmpty($Version)) { $Version = $ExpectedVersion }
if ($Version -cne $ExpectedVersion -or $Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'version does not match serverVersion' }
$Output = [IO.Path]::GetFullPath($Output)
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('image2-launcher-' + [Guid]::NewGuid().ToString('N'))
$AssetDir = Join-Path $Root 'cmd\windows-launcher\assets'
$Backup = Join-Path $Temp 'original-assets'
$Assets = Join-Path $Temp 'assets'
try {
  [IO.Directory]::CreateDirectory($Temp) | Out-Null
  [IO.Directory]::CreateDirectory($Assets) | Out-Null
  if (Test-Path -LiteralPath $AssetDir) { Move-Item -LiteralPath $AssetDir -Destination $Backup }
  foreach ($Relative in @('install.sh','install.ps1','go.mod','LICENSE','scripts/setup.sh','scripts/offline-binary.sh','scripts/offline-binary.ps1','scripts/run-image2-mcp.sh','scripts/run-image2-mcp.ps1','scripts/bootstrap-agent-install.sh','scripts/bootstrap-agent-install.ps1')) {
    $Source = Join-Path $Root $Relative
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "missing payload file: $Relative" }
    $AssetRelative = if ($Relative -eq 'go.mod') { 'go.mod.txt' } else { $Relative }
    $Destination = Join-Path (Join-Path $Assets 'payload') $AssetRelative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination)) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination
  }
  Copy-Item -LiteralPath (Join-Path $Root 'install-offline.ps1') -Destination (Join-Path $Assets 'install-offline.ps1')
  [IO.Directory]::CreateDirectory((Join-Path $Assets 'scripts')) | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'scripts\bootstrap-agent-install.ps1') -Destination (Join-Path $Assets 'scripts\bootstrap-agent-install.ps1')
  Copy-Item -LiteralPath (Join-Path $Root 'scripts\offline-binary.ps1') -Destination (Join-Path $Assets 'scripts\offline-binary.ps1')
  [IO.File]::WriteAllText((Join-Path $Assets 'version'), $Version + "`n", (New-Object Text.UTF8Encoding($false)))
  $Architectures = [ordered]@{}
  foreach ($Arch in @('386','amd64','arm64')) {
    $Binary = Join-Path (Join-Path $Assets 'payload\windows') ($Arch + '\image2-mcp.exe')
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Binary)) | Out-Null
    $env:GOOS = 'windows'; $env:GOARCH = $Arch; $env:CGO_ENABLED = '0'
    & go build -trimpath -o $Binary ./cmd/image2-mcp
    if ($LASTEXITCODE -ne 0) { throw "Go build failed for $Arch" }
    $Metadata = (& go version -m $Binary) -join "`n"
    if ($LASTEXITCODE -ne 0 -or ($Metadata -notmatch "(?m)^\s*build\s+GOOS=windows$") -or ($Metadata -notmatch "(?m)^\s*build\s+GOARCH=$Arch$")) { throw "payload metadata mismatch for $Arch" }
    $Hash = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash.ToLowerInvariant()
    $Architectures[$Arch] = [ordered]@{ sha256 = $Hash; size = (Get-Item -LiteralPath $Binary).Length }
  }
  [IO.File]::WriteAllText((Join-Path $Assets 'manifest.json'), ([ordered]@{ version = $Version; architectures = $Architectures } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
  [IO.Directory]::CreateDirectory($AssetDir) | Out-Null
  Copy-Item -Path (Join-Path $Assets '*') -Destination $AssetDir -Recurse -Force
  [IO.Directory]::CreateDirectory($Output) | Out-Null
  $env:GOOS = 'windows'; $env:GOARCH = '386'; $env:CGO_ENABLED = '0'
  $Launcher = Join-Path $Temp 'SchylerAI-Image2-mcp.exe'
  & go build -trimpath -ldflags '-H=windowsgui' -o $Launcher ./cmd/windows-launcher
  if ($LASTEXITCODE -ne 0) { throw 'launcher build failed' }
  Remove-Item Env:GOOS,Env:GOARCH,Env:CGO_ENABLED -ErrorAction SilentlyContinue
  $env:IMAGE2_BUILT_LAUNCHER = $Launcher
  & go test ./cmd/windows-launcher -run '^TestBuiltLauncherIncludesGeneratedPayloads$' -count=1
  if ($LASTEXITCODE -ne 0) { throw 'built launcher payload inclusion verification failed' }
  Remove-Item Env:IMAGE2_BUILT_LAUNCHER -ErrorAction SilentlyContinue
  Move-Item -LiteralPath $Launcher -Destination (Join-Path $Output 'SchylerAI-Image2-mcp.exe') -Force
  Copy-Item -LiteralPath (Join-Path $Assets 'manifest.json') -Destination (Join-Path $Output 'SchylerAI-Image2-mcp.manifest.json')
  Write-Host "Universal launcher: $(Join-Path $Output 'SchylerAI-Image2-mcp.exe')"
} finally {
  Remove-Item -LiteralPath $AssetDir -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $Backup) { Move-Item -LiteralPath $Backup -Destination $AssetDir }
  Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item Env:GOOS,Env:GOARCH,Env:CGO_ENABLED,Env:IMAGE2_BUILT_LAUNCHER -ErrorAction SilentlyContinue
  Pop-Location
}
