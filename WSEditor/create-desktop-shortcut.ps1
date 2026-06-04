param(
  [ValidateSet('Debug', 'Release')]
  [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$exePath = Join-Path $projectRoot "build\$Configuration\WSEditor.exe"
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'WSEditor.lnk'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exePath
$shortcut.WorkingDirectory = Split-Path $exePath
$shortcut.WindowStyle = 1
$shortcut.IconLocation = "$env:SystemRoot\System32\notepad.exe,0"
$shortcut.Description = 'WSEditor'
$shortcut.Save()

Write-Host "Shortcut created: $shortcutPath"
Write-Host "Target: $exePath"
