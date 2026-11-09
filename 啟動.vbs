Dim objFSO, objShell, scriptDir, trackPath
Set objFSO = CreateObject("Scripting.FileSystemObject")
scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
trackPath = scriptDir & "\track.ps1"

Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & trackPath & """", 0, False
