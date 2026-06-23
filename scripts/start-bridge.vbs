Option Explicit

Dim fso, shell, root, bridge, outLog, errLog, interval, quote, cmd

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

quote = Chr(34)
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
bridge = fso.BuildPath(root, "scripts\headroom-live-bridge.ps1")
outLog = fso.BuildPath(root, "bridge.log")
errLog = fso.BuildPath(root, "bridge.err.log")
interval = "5"

If WScript.Arguments.Count > 0 Then
  interval = WScript.Arguments(0)
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & quote & bridge & quote & _
  " -IntervalSeconds " & interval & _
  " -LogPath " & quote & outLog & quote & _
  " -ErrorLogPath " & quote & errLog & quote

shell.Run cmd, 0, False

WScript.Echo "Started Headroom Live Bridge"
WScript.Echo "STDOUT=" & outLog
WScript.Echo "STDERR=" & errLog
