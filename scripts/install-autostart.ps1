[CmdletBinding()]
param(
  [string]$MonitorRoot = (Split-Path -Parent (Split-Path -Parent $PSCommandPath)),
  [string]$ApiBase = "http://127.0.0.1:8787",
  [int]$IntervalSeconds = 5,
  [int]$StartupTimeoutSeconds = 300,
  [int]$RetrySeconds = 10,
  [string]$TaskName = "Headroom CYD Bridge"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

$resolvedMonitorRoot = (Resolve-Path -LiteralPath $MonitorRoot).Path
$headroomRoot = Join-Path $env:USERPROFILE ".headroom"
$logsRoot = Join-Path $headroomRoot "logs"
$supervisorPath = Join-Path $headroomRoot "start-headroom-cyd-bridge.ps1"
$vbsPath = Join-Path $headroomRoot "start-headroom-cyd-bridge-hidden.vbs"

New-Item -ItemType Directory -Force -Path $headroomRoot | Out-Null
New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null

$supervisorTemplate = @'
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$MonitorRoot = "__MONITOR_ROOT__"
$ApiBase = "__API_BASE__"
$IntervalSeconds = __INTERVAL_SECONDS__
$StartupTimeoutSeconds = __STARTUP_TIMEOUT_SECONDS__
$RetrySeconds = __RETRY_SECONDS__

$BridgeScript = Join-Path $MonitorRoot "scripts\headroom-live-bridge.ps1"
$LogRoot = Join-Path $env:USERPROFILE ".headroom\logs"
$SupervisorLog = Join-Path $LogRoot "cyd-bridge-supervisor.log"
$BridgeLog = Join-Path $LogRoot "cyd-bridge.log"
$BridgeErrLog = Join-Path $LogRoot "cyd-bridge.err.log"

function Write-SupervisorLog {
  param([string]$Message)

  $line = "[{0}] {1}" -f (Get-Date).ToString("HH:mm:ss"), $Message
  Add-Content -LiteralPath $SupervisorLog -Value $line
}

function Test-BridgeRunning {
  $escapedBridgeScript = [Regex]::Escape($BridgeScript)
  $processes = @(
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match $escapedBridgeScript
      }
  )

  return $processes.Count -gt 0
}

function Wait-ForHeadroom {
  $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-RestMethod -Uri ($ApiBase.TrimEnd('/') + "/health") -TimeoutSec 5
      if ($null -ne $response) {
        Write-SupervisorLog "Headroom API ready at $ApiBase"
        return $true
      }
    } catch {
    }

    Start-Sleep -Seconds 2
  }

  Write-SupervisorLog "Headroom API not ready after $StartupTimeoutSeconds s"
  return $false
}

New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
Write-SupervisorLog "supervisor started for $MonitorRoot"

while ($true) {
  if (-not (Test-Path -LiteralPath $BridgeScript)) {
    Write-SupervisorLog "bridge script not found: $BridgeScript"
    Start-Sleep -Seconds $RetrySeconds
    continue
  }

  if (Test-BridgeRunning) {
    Write-SupervisorLog "bridge already running"
    Start-Sleep -Seconds $RetrySeconds
    continue
  }

  if (-not (Wait-ForHeadroom)) {
    Start-Sleep -Seconds $RetrySeconds
    continue
  }

  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $BridgeScript,
    "-IntervalSeconds", $IntervalSeconds,
    "-ApiBase", $ApiBase,
    "-LogPath", $BridgeLog,
    "-ErrorLogPath", $BridgeErrLog
  )

  Write-SupervisorLog "starting bridge from $BridgeScript"
  try {
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
    $exitCode = if ($null -ne $process.ExitCode) { $process.ExitCode } else { 0 }
    Write-SupervisorLog "bridge exited with code $exitCode"
  } catch {
    Write-SupervisorLog "bridge launch failed: $($_.Exception.Message)"
  }

  Start-Sleep -Seconds $RetrySeconds
}
'@

$supervisorContent = $supervisorTemplate
$supervisorContent = $supervisorContent.Replace("__MONITOR_ROOT__", $resolvedMonitorRoot.Replace("\", "\\"))
$supervisorContent = $supervisorContent.Replace("__API_BASE__", $ApiBase)
$supervisorContent = $supervisorContent.Replace("__INTERVAL_SECONDS__", [string]$IntervalSeconds)
$supervisorContent = $supervisorContent.Replace("__STARTUP_TIMEOUT_SECONDS__", [string]$StartupTimeoutSeconds)
$supervisorContent = $supervisorContent.Replace("__RETRY_SECONDS__", [string]$RetrySeconds)

$vbsContent = @'
Dim shell
Dim fso
Dim root
Dim command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & fso.BuildPath(root, "start-headroom-cyd-bridge.ps1") & Chr(34)

shell.Run command, 0, True
'@

Write-Utf8NoBom -Path $supervisorPath -Content $supervisorContent
Write-Utf8NoBom -Path $vbsPath -Content $vbsContent

$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument ('"{0}"' -f $vbsPath)
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
$settings.ExecutionTimeLimit = "PT0S"
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

$installedTaskName = $TaskName
$triggerMode = "logon + startup"
$registrationMode = "Register-ScheduledTask"
try {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logonTrigger, $startupTrigger) -Settings $settings -Principal $principal -Force | Out-Null
} catch {
  try {
    $triggerMode = "logon only"
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $logonTrigger -Settings $settings -Principal $principal -Force | Out-Null
  } catch {
    $installedTaskName = "$TaskName (User)"
    $triggerMode = "logon only"
    $registrationMode = "schtasks.exe"
    try {
      $taskRun = ('"{0}" "{1}"' -f "$env:SystemRoot\System32\wscript.exe", $vbsPath)
      $createArgs = @(
        "/Create",
        "/F",
        "/SC", "ONLOGON",
        "/TN", $installedTaskName,
        "/TR", $taskRun,
        "/RL", "LIMITED",
        "/IT"
      )

      & schtasks.exe @createArgs | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "schtasks.exe failed with exit code $LASTEXITCODE"
      }
    } catch {
      throw "Wrappers generated in $headroomRoot, but Windows denied scheduled-task registration. Re-run this script from a context allowed to manage Task Scheduler, or keep using scripts\start-bridge.ps1 manually."
    }
  }
}

Write-Host "Installed Headroom CYD autostart."
Write-Host "Task: $installedTaskName"
Write-Host "Triggers: $triggerMode"
Write-Host "Registration: $registrationMode"
Write-Host "Supervisor: $supervisorPath"
Write-Host "Hidden launcher: $vbsPath"
