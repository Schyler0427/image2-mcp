$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
& (Join-Path $root 'scripts\bootstrap-agent-install.ps1') -OfflinePackage (Join-Path $root 'payload')
