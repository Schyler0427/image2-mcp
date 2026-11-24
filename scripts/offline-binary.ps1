function Test-OfflineBinary([string]$Root) {
  $OfflineDist = Get-Item -LiteralPath (Join-Path $Root "dist") -Force -ErrorAction SilentlyContinue
  $OfflineBinary = Get-Item -LiteralPath (Join-Path $Root "dist\image2-mcp.exe") -Force -ErrorAction SilentlyContinue
  if ($null -eq $OfflineDist -or -not $OfflineDist.PSIsContainer -or
      (($OfflineDist.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or $null -eq $OfflineBinary -or
      $OfflineBinary.PSIsContainer -or (($OfflineBinary.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
      $OfflineBinary.Length -le 0) {
    throw "offline package is missing a regular bundled binary"
  }
  $Process = New-Object Diagnostics.Process
  $Process.StartInfo = New-Object Diagnostics.ProcessStartInfo
  $Process.StartInfo.FileName = $OfflineBinary.FullName
  $Process.StartInfo.Arguments = "--version"
  $Process.StartInfo.UseShellExecute = $false
  $Process.StartInfo.CreateNoWindow = $true
  $Process.StartInfo.RedirectStandardInput = $true
  $Process.StartInfo.RedirectStandardOutput = $true
  $Process.StartInfo.RedirectStandardError = $true
  foreach ($Name in @("OPENAI_IMAGE_API_KEY", "OPENAI_IMAGE_BASE_URL", "OPENAI_IMAGE_MODEL", "GEMINI_IMAGE_API_KEY", "GEMINI_IMAGE_BASE_URL", "GEMINI_IMAGE_MODEL")) {
    $Process.StartInfo.EnvironmentVariables.Remove($Name)
  }
  $Started = $false
  try {
    $Started = $Process.Start()
    $Process.StandardInput.Close()
    $OutputTask = $Process.StandardOutput.ReadToEndAsync()
    $ErrorTask = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit(5000)) { throw "timeout" }
    $NativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $Arch = switch ($NativeArchitecture.ToUpperInvariant()) { "ARM64" { "arm64" }; "AMD64" { "amd64" }; "X86" { "386" }; default { throw "unsupported architecture" } }
    $Expected = "image2-mcp 0.4.4 offline-v1 windows $Arch"
    if ($Process.ExitCode -ne 0 -or -not $OutputTask.Wait(1000) -or
        $OutputTask.Result.TrimEnd([char[]]@("`r", "`n")) -cne $Expected) {
      throw "version or platform mismatch"
    }
  } catch {
    throw "offline binary version/platform check failed"
  } finally {
    try {
      if ($Started -and -not $Process.HasExited) {
        $Killer = $null
        try {
          $Info = New-Object Diagnostics.ProcessStartInfo
          $Info.FileName = Join-Path $env:SystemRoot "System32\taskkill.exe"
          $Info.Arguments = "/PID $($Process.Id) /T /F"
          $Info.UseShellExecute = $false
          foreach ($Name in @("OPENAI_IMAGE_API_KEY", "GEMINI_IMAGE_API_KEY")) {
            $Info.EnvironmentVariables.Remove($Name)
          }
          $Info.CreateNoWindow = $true
          $Info.RedirectStandardOutput = $true
          $Info.RedirectStandardError = $true
          $Killer = [Diagnostics.Process]::Start($Info)
          if (-not $Killer.WaitForExit(1000)) { $Killer.Kill() }
        } catch {
          # Force the direct child below if taskkill is unavailable.
        } finally {
          if ($null -ne $Killer) { $Killer.Dispose() }
          if (-not $Process.HasExited) { $Process.Kill() }
          [void]$Process.WaitForExit(1000)
        }
      }
    } finally { $Process.Dispose() }
  }
}
