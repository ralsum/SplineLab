param(
  [ValidateSet('Debug', 'Release')]
  [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDir = Join-Path $projectRoot 'build'

cmake -S $projectRoot -B $buildDir -A x64
cmake --build $buildDir --config $Configuration
& (Join-Path $projectRoot 'create-desktop-shortcut.ps1') -Configuration $Configuration
