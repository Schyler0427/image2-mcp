#requires -Version 5.1
$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

function Get-FileFingerprint([string]$Path) {
  Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "required file is missing: $Path"
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Stop-TestProcessTree([Diagnostics.Process]$Process) {
  $TreeKiller = $null
  try {
    # Kill(true) is unavailable in .NET Framework / Windows PowerShell 5.1.
    $Info = New-Object Diagnostics.ProcessStartInfo
    $Info.FileName = Join-Path $env:SystemRoot "System32\taskkill.exe"
    $Info.Arguments = "/PID $($Process.Id) /T /F"
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $TreeKiller = [Diagnostics.Process]::Start($Info)
    if (-not $TreeKiller.WaitForExit(5000)) {
      $TreeKiller.Kill()
      [void]$TreeKiller.WaitForExit(5000)
    }
  } catch {
    # A child may exit between the timeout and taskkill; still try the root.
  } finally {
    if ($null -ne $TreeKiller) { $TreeKiller.Dispose() }
    if (-not $Process.WaitForExit(5000)) {
      $Process.Kill()
      [void]$Process.WaitForExit(5000)
    }
  }
}

function Invoke-TestChild(
  [string]$Executable,
  [string[]]$ChildArguments,
  [hashtable]$ChildEnvironment = @{},
  [string]$InputText = "",
  [int]$TimeoutMilliseconds = 60000
) {
  $Info = New-Object Diagnostics.ProcessStartInfo
  $Info.FileName = $Executable
  # Invoke the executable directly: no cmd.exe / shell expansion of temp paths.
  # All arguments here are flags or file paths (no embedded quotes or trailing \).
  foreach ($Argument in $ChildArguments) {
    Assert-True (-not $Argument.Contains('"') -and -not $Argument.EndsWith('\')) "unsafe test process argument"
  }
  $Info.Arguments = ($ChildArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $Info.WorkingDirectory = $Root
  $Info.UseShellExecute = $false
  $Info.CreateNoWindow = $true
  $Info.RedirectStandardInput = $true
  $Info.RedirectStandardOutput = $true
  $Info.RedirectStandardError = $true
  # Only child environments change. In particular, never assign automatic $HOME
  # or change the parent's HOME/USERPROFILE, PATH, proxies, or Go configuration.
  foreach ($Name in $ChildEnvironment.Keys) {
    if ($null -eq $ChildEnvironment[$Name]) {
      $Info.EnvironmentVariables.Remove($Name)
    } else {
      $Info.EnvironmentVariables[$Name] = [string]$ChildEnvironment[$Name]
    }
  }
  $Process = New-Object Diagnostics.Process
  $Process.StartInfo = $Info
  $Started = $false
  $Completed = $false
  try {
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
      throw "test executable is missing: $Executable"
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
      throw "test working directory is missing: $Root"
    }
    try {
      $Started = $Process.Start()
    } catch {
      throw "could not start test child '$Executable' in '$Root': $($_.Exception.Message)"
    }
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    # The harmless Key goes only to attached stdin, never an argument, inherited
    # environment variable, PowerShell pipeline, or temporary input file.
    try {
      if ($InputText.Length -gt 0) { $Process.StandardInput.Write($InputText) }
    } finally { $Process.StandardInput.Close() }
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
      throw "test child timed out after $TimeoutMilliseconds milliseconds"
    }
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($StdoutTask, $StderrTask), 5000)) {
      throw "test child output did not close"
    }
    $Completed = ($Process.ExitCode -eq 0)
    return [PSCustomObject]@{
      ExitCode = $Process.ExitCode
      Output = $StdoutTask.Result + $StderrTask.Result
    }
  } finally {
    try {
      if ($Started -and (-not $Completed -or -not $Process.HasExited)) {
        Stop-TestProcessTree $Process
      }
    } finally { $Process.Dispose() }
  }
}

function Assert-NoKeyLeak([string]$Output) {
  Assert-True (-not $Output.Contains($SecretText)) "offline installation exposed the test Key"
}

function Assert-Verified($Result, [string]$Label) {
  # Check this before including diagnostics in any assertion failure.
  Assert-NoKeyLeak $Result.Output
  Assert-True ($Result.ExitCode -eq 0) "$Label failed: $($Result.Output)"
  Assert-True (($Result.Output -split '\r?\n') -ccontains "Verification: OK") "$Label did not verify MCP"
}

function Assert-UnrelatedMcp {
  $Text = [IO.File]::ReadAllText($ConfigFile)
  Assert-True ($Text.Contains($KeepConfig)) "offline installation changed the unrelated MCP server"
  Assert-NoKeyLeak $Text
  Assert-True (-not $Text.Contains("OPENAI_IMAGE_API_KEY")) "Codex config contains an API Key setting"
  Assert-True (([regex]::Matches($Text, '(?m)^\[mcp_servers\.image2\]\r?$')).Count -eq 1) "image2 MCP config is missing or duplicated"
}

Assert-True ($env:OS -eq "Windows_NT" -and $PSVersionTable.PSEdition -eq "Desktop") "run this test in Windows PowerShell 5.1"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PowerShell = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
$Go = (Get-Command go.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$NativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$Arch = switch ($NativeArchitecture.ToUpperInvariant()) {
  "ARM64" { "arm64" }
  "AMD64" { "amd64" }
  "X86" { "386" }
  default { throw "unsupported offline test architecture: $env:PROCESSOR_ARCHITECTURE" }
}
$VersionMatch = [regex]::Match([IO.File]::ReadAllText((Join-Path $Root "cmd\image2-mcp\main.go")), '(?m)^const serverVersion = "([^"\r\n]+)"\r?$')
Assert-True $VersionMatch.Success "could not read serverVersion from main.go"
$Version = $VersionMatch.Groups[1].Value
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("image2 offline install-" + [Guid]::NewGuid().ToString("N"))
$Package = Join-Path $TempRoot "offline package"
$Payload = Join-Path $Package "payload"
$TestHome = Join-Path $TempRoot "customer home"
$LocalAppData = Join-Path $TestHome "AppData\Local"
$Target = Join-Path $LocalAppData "image2-mcp"
$ConfigFile = Join-Path $TestHome ".codex\config.toml"
$EnvFile = Join-Path $Target ".env.local"
$InstalledBinary = Join-Path $Target "dist\image2-mcp.exe"
$Forbid = Join-Path $TempRoot "forbidden commands"
$ForbiddenLog = Join-Path $TempRoot "forbidden.log"
$SecretText = "offline-install-test-value"
  $ReplacementGeminiKey = "replacement-gemini-key-value"
$Encoding = New-Object Text.UTF8Encoding($false)
$KeepConfig = "[mcp_servers.keep]`r`ncommand = 'C:\keep\runner.exe'`r`nargs = ['keep-this-argument']`r`n"

try {
  [IO.Directory]::CreateDirectory($TempRoot) | Out-Null
  $BuiltBinary = Join-Path $TempRoot "image2-mcp.exe"
  # Build the real server using the installed Windows Go BEFORE isolating the
  # customer profile or blocking build/network commands. Keep Go's real caches.
  $Build = Invoke-TestChild -Executable $Go -ChildArguments @("build", "-o", $BuiltBinary, "./cmd/image2-mcp") `
    -ChildEnvironment @{ GOOS = "windows"; GOARCH = $Arch; CGO_ENABLED = "0" } -TimeoutMilliseconds 300000
  Assert-True ($Build.ExitCode -eq 0) "native Go build failed: $($Build.Output)"
  $Metadata = Invoke-TestChild -Executable $Go -ChildArguments @("version", "-m", $BuiltBinary)
  Assert-True ($Metadata.ExitCode -eq 0 -and $Metadata.Output -match '(?m)^\s*build\s+GOOS=windows\r?$' -and
    $Metadata.Output -match ('(?m)^\s*build\s+GOARCH=' + $Arch + '\r?$')) "Go binary build platform does not match the package"

  foreach ($Directory in @((Join-Path $Payload "scripts"), (Join-Path $Payload "dist"),
    (Join-Path $Package "scripts"), (Join-Path $TestHome ".codex"), $LocalAppData, $Forbid)) {
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
  }
  # Exactly the paths and order in scripts/build-offline-package.sh; copy bytes
  # without text conversion, including both wrappers and root bootstrap helpers.
  $PayloadPaths = @("install.sh", "install.ps1", "go.mod", "LICENSE", "scripts/setup.sh",
    "scripts/offline-binary.sh", "scripts/offline-binary.ps1", "scripts/run-image2-mcp.sh",
    "scripts/run-image2-mcp.ps1", "scripts/bootstrap-agent-install.sh", "scripts/bootstrap-agent-install.ps1",
    "dist/image2-mcp.exe")
  foreach ($Relative in $PayloadPaths) {
    $Source = if ($Relative -ceq "dist/image2-mcp.exe") { $BuiltBinary } else { Join-Path $Root $Relative }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $Payload $Relative)
  }
  foreach ($Relative in @("install-offline.sh", "install-offline.ps1", "OFFLINE_INSTALL.md",
    "scripts/bootstrap-agent-install.sh", "scripts/bootstrap-agent-install.ps1")) {
    Copy-Item -LiteralPath (Join-Path $Root $Relative) -Destination (Join-Path $Package $Relative)
  }
  [IO.File]::WriteAllText((Join-Path $Package "OFFLINE_PACKAGE_VERSION"), ($Version + "`n"), $Encoding)
  $Manifest = @("IMAGE2_MCP_OFFLINE 1", "version $Version", "platform windows $Arch")
  foreach ($Relative in $PayloadPaths) {
    $File = Get-Item -LiteralPath (Join-Path $Payload $Relative)
    $Hash = Get-FileFingerprint $File.FullName
    $Manifest += "file $Hash $($File.Length) $Relative"
  }
  Assert-True ($Manifest.Count -eq 15) "offline manifest must have exactly 15 lines"
  [IO.File]::WriteAllText((Join-Path $Payload "OFFLINE_PACKAGE_MANIFEST"), (($Manifest -join "`n") + "`n"), $Encoding)
  Assert-True (@(Get-ChildItem -LiteralPath $Payload -Recurse -Force -File).Count -eq 14) "offline payload must have 13 files plus its manifest"
  [IO.File]::WriteAllText($ConfigFile, $KeepConfig, $Encoding)

  # Real .exe shims also catch explicit go.exe/curl.exe calls; unlike .cmd shims
  # they do not depend on PATHEXT or shell quoting. No customer Key in this code.
  $Shim = Join-Path $Forbid "go.exe"
  Add-Type -OutputAssembly $Shim -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public static class Image2OfflineForbiddenCommand {
    public static int Main() {
        File.AppendAllText(Environment.GetEnvironmentVariable("IMAGE2_OFFLINE_FORBIDDEN_LOG"),
            "forbidden command: " + Path.GetFileName(Environment.GetCommandLineArgs()[0]) + "\n");
        return 97;
    }
}
'@
  foreach ($Name in @("curl", "wget", "git")) {
    Copy-Item -LiteralPath $Shim -Destination (Join-Path $Forbid ($Name + ".exe"))
  }
  $ChildEnvironment = @{
    HOME = $TestHome
    USERPROFILE = $TestHome
    LOCALAPPDATA = $LocalAppData
    PATH = $Forbid + ";" + (Split-Path -Parent $PowerShell) + ";" + (Join-Path $env:SystemRoot "System32") + ";" + $env:PATH
    HTTP_PROXY = "http://127.0.0.1:9"
    HTTPS_PROXY = "http://127.0.0.1:9"
    ALL_PROXY = "http://127.0.0.1:9"
    NO_PROXY = $null
    OPENAI_IMAGE_API_KEY = $null
    OPENAI_IMAGE_BASE_URL = $null
    OPENAI_IMAGE_MODEL = $null
    IMAGE2_OFFLINE_FORBIDDEN_LOG = $ForbiddenLog
  }
  $InstallerArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $Package "install-offline.ps1"))
  $First = Invoke-TestChild -Executable $PowerShell -ChildArguments $InstallerArguments `
    -ChildEnvironment $ChildEnvironment -InputText ($SecretText + "`r`n")
  Assert-Verified $First "real offline package installation"
  Assert-UnrelatedMcp
  Assert-True ((Get-FileFingerprint $InstalledBinary) -ceq (Get-FileFingerprint $BuiltBinary)) "installation replaced the bundled binary"
  Assert-True (([IO.File]::ReadAllText($EnvFile) -split '\r?\n') -ccontains ('OPENAI_IMAGE_API_KEY="' + $SecretText + '"')) "installer did not save the Key supplied on stdin"
  $EnvBefore = Get-FileFingerprint $EnvFile
  $BinaryBefore = Get-FileFingerprint $InstalledBinary

  # Repeat must request and save an independently supplied Image2 Key.
  $ReplacementKey = "replacement-image-key-value"
  $Repeat = Invoke-TestChild -Executable $PowerShell -ChildArguments $InstallerArguments -ChildEnvironment $ChildEnvironment -InputText ($ReplacementKey + "`r`n")
  Assert-Verified $Repeat "real offline package repeat"
  Assert-True (-not $Repeat.Output.Contains("reusing it")) "repeat reused the saved Key"
  Assert-True ($Repeat.Output.Contains("OPENAI_IMAGE_API_KEY:")) "repeat did not prompt for Image2 Key"
  Assert-True (-not $Repeat.Output.Contains($ReplacementKey)) "repeat leaked replacement Key"
  Assert-True (([IO.File]::ReadAllText($EnvFile) -split '\r?\n') -ccontains ('OPENAI_IMAGE_API_KEY="' + $ReplacementKey + '"')) "repeat ignored replacement Image2 Key"
  Assert-True ((Get-FileFingerprint $InstalledBinary) -ceq $BinaryBefore) "repeat changed the bundled binary"
  Assert-UnrelatedMcp
  $Backups = @(Get-ChildItem -LiteralPath $LocalAppData -Directory -Filter "image2-mcp.backup.*")
  Assert-True ($Backups.Count -eq 1) "repeat did not retain exactly one backup"
  $Previous = Join-Path $Backups[0].FullName "previous"
  Assert-True (($Repeat.Output -split '\r?\n') -ccontains "Previous installation retained at: $Previous") "repeat did not report the retained backup"
  Assert-True ((Get-FileFingerprint (Join-Path $Previous ".env.local")) -ceq $EnvBefore) "backup did not retain the saved environment"
  Assert-True ((Get-FileFingerprint (Join-Path $Previous "dist\image2-mcp.exe")) -ceq $BinaryBefore) "backup did not retain the old binary"

  foreach ($Provider in @("image2", "gemini")) {
    $OptionalInput = if ($Provider -eq "image2") { $ReplacementKey + "`r`n `t`r`n" } else { " `t`r`n" + $ReplacementGeminiKey + "`r`n" }
    $ChildEnvironment.OPENAI_IMAGE_API_KEY = "ambient-image-key"
    $ChildEnvironment.GEMINI_IMAGE_API_KEY = "ambient-gemini-key"
    $Optional = Invoke-TestChild -Executable $PowerShell -ChildArguments $InstallerArguments -ChildEnvironment $ChildEnvironment -InputText $OptionalInput
    Assert-Verified $Optional "$Provider-only offline installation"
    $EnvLines = [IO.File]::ReadAllLines($EnvFile)
    if ($Provider -eq "image2") {
      Assert-True ($EnvLines -ccontains ('OPENAI_IMAGE_API_KEY="' + $ReplacementKey + '"')) "Image2-only key was not saved"
      Assert-True ($EnvLines -ccontains 'GEMINI_IMAGE_API_KEY=""') "Image2-only retained an old Gemini key"
    } else {
      Assert-True ($EnvLines -ccontains 'OPENAI_IMAGE_API_KEY=""') "Gemini-only retained an old Image2 key"
      Assert-True ($EnvLines -ccontains ('GEMINI_IMAGE_API_KEY="' + $ReplacementGeminiKey + '"')) "Gemini-only key was not saved"
    }
    Assert-UnrelatedMcp
  }
  $OptionalEnvBefore = Get-FileFingerprint $EnvFile
  $OptionalConfigBefore = Get-FileFingerprint $ConfigFile
  $Empty = Invoke-TestChild -Executable $PowerShell -ChildArguments $InstallerArguments -ChildEnvironment $ChildEnvironment -InputText " `t`r`n `t`r`n"
  Assert-True ($Empty.ExitCode -ne 0) "two empty provider keys were accepted"
  Assert-True ((Get-FileFingerprint $EnvFile) -ceq $OptionalEnvBefore) "empty keys changed credentials"
  Assert-True ((Get-FileFingerprint $ConfigFile) -ceq $OptionalConfigBefore) "empty keys changed Codex config"

  $EnvBefore = Get-FileFingerprint $EnvFile
  $ConfigBefore = Get-FileFingerprint $ConfigFile
  # Keep the byte count unchanged so this exercises SHA-256 validation itself.
  $BundledBinary = Join-Path $Payload "dist\image2-mcp.exe"
  $Bytes = [IO.File]::ReadAllBytes($BundledBinary)
  $Bytes[$Bytes.Length - 1] = $Bytes[$Bytes.Length - 1] -bxor 1
  [IO.File]::WriteAllBytes($BundledBinary, $Bytes)
  $Damaged = Invoke-TestChild -Executable $PowerShell -ChildArguments $InstallerArguments -ChildEnvironment $ChildEnvironment
  Assert-NoKeyLeak $Damaged.Output
  Assert-True ($Damaged.ExitCode -ne 0) "damaged real package was accepted"
  # PowerShell 5.1 may wrap long errors; allow whitespace inside the diagnostic.
  Assert-True ($Damaged.Output -match 'offline package SHA-256\s+mismatch') "damaged package did not fail manifest verification: $($Damaged.Output)"
  Assert-True (-not $Damaged.Output.Contains("OPENAI_IMAGE_API_KEY:")) "damaged package prompted for a Key"
  Assert-True (-not (($Damaged.Output -split '\r?\n') -ccontains "Verification: OK")) "damaged package reported success"
  Assert-True ((Get-FileFingerprint $ConfigFile) -ceq $ConfigBefore) "damaged package changed Codex config"
  Assert-True ((Get-FileFingerprint $InstalledBinary) -ceq $BinaryBefore) "damaged package changed the old binary"
  Assert-True ((Get-FileFingerprint $EnvFile) -ceq $EnvBefore) "damaged package changed the saved environment"
  Assert-True ((Get-FileFingerprint (Join-Path $Previous "dist\image2-mcp.exe")) -ceq $BinaryBefore) "damaged package changed the retained backup"
  Assert-True (-not (Test-Path -LiteralPath $ForbiddenLog)) "offline installation called a forbidden network/build command"
  Write-Host "PASS: real offline package install, repeat, MCP handshake, and damaged-package refusal"
} finally {
  if (Test-Path -LiteralPath $TempRoot) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force
  }
}
