[CmdletBinding()]
param(
  [int]$IntervalSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$launcher = Join-Path $root "scripts\start-bridge.vbs"
& cscript.exe //nologo $launcher $IntervalSeconds
