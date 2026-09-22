' start-hidden.vbs
'
' Launches winshot2clip.ps1 with no visible console window.
'
' WScript.Shell.Run's window style 0 is what actually keeps the black
' console from flashing on screen at every logon. Relying on
' "powershell.exe -WindowStyle Hidden" alone still flashes one briefly.
'
' Like the PowerShell script, this file is deliberately ASCII-only: that
' way it survives any transfer method and any system codepage.
'
' To autostart: put a shortcut to this file in  shell:startup
' (i.e. %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup).

Option Explicit

Dim fso, shell, scriptDir, ps1, command

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1       = fso.BuildPath(scriptDir, "winshot2clip.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "Cannot find:" & vbCrLf & ps1, 16, "winshot2clip"
    WScript.Quit 1
End If

command = "powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass" _
        & " -WindowStyle Hidden -File """ & ps1 & """"

' 0 = hidden window, False = do not wait for it to exit.
shell.Run command, 0, False
