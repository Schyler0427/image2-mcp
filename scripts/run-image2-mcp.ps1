$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir

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
    $Value = ConvertFrom-DotEnvValue $Parts[1].Trim()
    [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
  }
}

Import-DotEnv (Join-Path $RepoDir ".env.local")
Import-DotEnv (Join-Path $RepoDir ".env")

& (Join-Path $RepoDir "dist\image2-mcp.exe")
exit $LASTEXITCODE
