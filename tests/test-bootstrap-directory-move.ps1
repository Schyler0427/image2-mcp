#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Bootstrap = Join-Path $Root 'scripts/bootstrap-agent-install.ps1'
. $Bootstrap

function Assert-MoveTest([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

Assert-MoveTest ($null -ne (Get-Command Move-AgentBootstrapDirectory -ErrorAction SilentlyContinue)) 'bounded bootstrap directory move helper is missing'
$NativeMove = (Get-Command Move-AgentBootstrapDirectoryOnce).ScriptBlock
$script:MoveCalls = 0
$script:MoveWaits = 0
$script:MoveFailures = 0
$script:MoveTestError = $null

# Replace only the native move boundary and timer. The production retry loop,
# exception classification, attempt limit, and exception propagation run intact.
function Move-AgentBootstrapDirectoryOnce([string]$Source, [string]$Destination) {
  $script:MoveCalls++
  Assert-MoveTest ($Source -ceq 'source' -and $Destination -ceq 'destination') 'move changed its arguments'
  if ($script:MoveCalls -le $script:MoveFailures) { throw $script:MoveTestError }
}
function Start-Sleep([int]$Seconds) {
  Assert-MoveTest ($Seconds -eq 1) 'retry delay must be exactly one second'
  $script:MoveWaits++
}

function Invoke-MoveTestCase([Exception]$Failure, [int]$FailureCount, [int]$ExpectedCalls, [int]$ExpectedWaits, [bool]$ExpectFailure) {
  $script:MoveCalls = 0
  $script:MoveWaits = 0
  $script:MoveFailures = $FailureCount
  $script:MoveTestError = $Failure
  $Caught = $null
  try { Move-AgentBootstrapDirectory 'source' 'destination' } catch { $Caught = $_.Exception.GetBaseException() }
  Assert-MoveTest ($script:MoveCalls -eq $ExpectedCalls) "move attempts: expected $ExpectedCalls, got $script:MoveCalls"
  Assert-MoveTest ($script:MoveWaits -eq $ExpectedWaits) "retry waits: expected $ExpectedWaits, got $script:MoveWaits"
  if ($ExpectFailure) {
    Assert-MoveTest ([object]::ReferenceEquals($Caught, $Failure)) 'move must preserve the original failure'
  } else {
    Assert-MoveTest ($null -eq $Caught) "transient move did not recover: $Caught"
  }
}

$Denied = New-Object UnauthorizedAccessException('fixture access denied')
$Sharing = New-Object IO.IOException('fixture sharing violation', -2147024864)
$Locked = New-Object IO.IOException('fixture lock violation', -2147024863)
$Other = New-Object IO.IOException('fixture destination already exists', -2147024713)
$Invalid = New-Object ArgumentException('fixture invalid path')
Invoke-MoveTestCase $Denied 0 1 0 $false
Invoke-MoveTestCase $Denied 2 3 2 $false
Invoke-MoveTestCase $Sharing 5 6 5 $false
Invoke-MoveTestCase $Locked 1 2 1 $false
Invoke-MoveTestCase $Denied 10 6 5 $true
Invoke-MoveTestCase $Sharing 10 6 5 $true
Invoke-MoveTestCase $Other 10 1 0 $true
Invoke-MoveTestCase $Invalid 10 1 0 $true

# Exercise the real filesystem operation after restoring the native boundary.
Set-Item Function:Move-AgentBootstrapDirectoryOnce $NativeMove
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('image2-move-test-' + [Guid]::NewGuid().ToString('N'))
try {
  $Source = Join-Path $Temp 'source'
  $Destination = Join-Path $Temp 'destination'
  [IO.Directory]::CreateDirectory($Source) | Out-Null
  [IO.File]::WriteAllText((Join-Path $Source 'sentinel.txt'), 'preserve me')
  Move-AgentBootstrapDirectory $Source $Destination
  Assert-MoveTest (-not [IO.Directory]::Exists($Source)) 'real move left the source in place'
  Assert-MoveTest ([IO.File]::ReadAllText((Join-Path $Destination 'sentinel.txt')) -ceq 'preserve me') 'real move changed the payload'
} finally {
  if ([IO.Directory]::Exists($Temp)) { [IO.Directory]::Delete($Temp, $true) }
}

# All transaction moves must share the retry helper, including rollback.
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($Bootstrap, [ref]$Tokens, [ref]$ParseErrors)
Assert-MoveTest ($ParseErrors.Count -eq 0) 'bootstrap has PowerShell syntax errors'
$MoveCommands = @($Ast.FindAll({
  param($Node)
  $Node -is [Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -ceq 'Move-AgentBootstrapDirectory'
}, $true))
Assert-MoveTest ($MoveCommands.Count -eq 4) 'activation, backup, failed-target retention, and restoration must all use bounded moves'

Write-Host 'PASS: directory move retries, bounded failures, original errors, real moves, and transaction integration'
