[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskName = "Headroom CYD Bridge"
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and $task.State -eq "Running") {
  Stop-ScheduledTask -TaskName $taskName
  "Stopped scheduled task: $taskName"
}

$processes = @(
  Get-CimInstance Win32_Process |
    Where-Object {
      $_.CommandLine -like "*headroom-live-bridge.ps1*" -or
      $_.CommandLine -like "*start-bridge-task.ps1*" -or
      $_.CommandLine -like "*start-bridge-task-hidden.vbs*" -or
      $_.CommandLine -like "*start-headroom-cyd-bridge.ps1*" -or
      $_.CommandLine -like "*start-headroom-cyd-bridge-hidden.vbs*"
    }
)
$pids = @($processes | ForEach-Object { [int]$_.ProcessId })

if (-not $pids) {
  "No Headroom Live Bridge process found."
  exit 0
}

foreach ($pidValue in $pids) {
  & taskkill.exe /PID $pidValue /F | Out-String | Write-Output
}
