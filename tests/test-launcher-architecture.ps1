[CmdletBinding()]
param(
  [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"

# Parse the real installer scripts, but run only their architecture assignments.
# Dot-sourcing either installer here would risk installing or changing user data.
function Get-ArchitectureSelector([string]$Path) {
  $Tokens = $null
  $ParseErrors = $null
  $Ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
  if ($ParseErrors.Count -ne 0) {
    throw "could not parse architecture source: $Path"
  }

  $Assignments = @($Ast.FindAll({
    param($Node)
    $Node -is [Management.Automation.Language.AssignmentStatementAst] -and
      $Node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
      @("NativeArchitecture", "Arch") -ccontains $Node.Left.VariablePath.UserPath
  }, $true))
  foreach ($Name in @("NativeArchitecture", "Arch")) {
    $Matching = @($Assignments | Where-Object { $_.Left.VariablePath.UserPath -ceq $Name })
    if ($Matching.Count -ne 1) {
      throw "expected exactly one $Name assignment in $Path"
    }
  }

  $Statements = @($Assignments | Sort-Object { $_.Extent.StartOffset } | ForEach-Object { $_.Extent.Text })
  return [scriptblock]::Create(($Statements -join "`n") + "`n" + '$Arch')
}

$Cases = @(
  @{ Name = "native x86"; Process = "x86"; Native = $null; Expected = "386" },
  @{ Name = "native x64"; Process = "AMD64"; Native = $null; Expected = "amd64" },
  @{ Name = "native ARM64"; Process = "ARM64"; Native = $null; Expected = "arm64" },
  @{ Name = "WOW64 x86 on x64"; Process = "x86"; Native = "AMD64"; Expected = "amd64" },
  @{ Name = "WOW64 x86 on ARM64"; Process = "x86"; Native = "ARM64"; Expected = "arm64" }
)

$PreviousProcessArchitecture = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "Process")
$PreviousNativeArchitecture = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITEW6432", "Process")
$Assertions = 0
try {
  foreach ($Relative in @("scripts\bootstrap-agent-install.ps1", "scripts\offline-binary.ps1")) {
    $Path = Join-Path $RepositoryRoot $Relative
    $Selector = Get-ArchitectureSelector $Path
    foreach ($Case in $Cases) {
      [Environment]::SetEnvironmentVariable("PROCESSOR_ARCHITECTURE", $Case.Process, "Process")
      [Environment]::SetEnvironmentVariable("PROCESSOR_ARCHITEW6432", $Case.Native, "Process")
      $Actual = & $Selector
      if ($Actual -isnot [string] -or $Actual -cne $Case.Expected) {
        throw "$Relative selected '$Actual' for $($Case.Name); expected '$($Case.Expected)'"
      }
      $Assertions++
    }
  }
} finally {
  [Environment]::SetEnvironmentVariable("PROCESSOR_ARCHITECTURE", $PreviousProcessArchitecture, "Process")
  [Environment]::SetEnvironmentVariable("PROCESSOR_ARCHITEW6432", $PreviousNativeArchitecture, "Process")
}

Write-Host "PASS: launcher architecture selection ($Assertions native/WOW64 assertions)"
