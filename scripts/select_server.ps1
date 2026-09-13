[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Server,

    [string]$ServerConfigPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\VaspTaskBackup.psm1') -Force
Get-VaspServer -Server $Server -ServerConfigPath $ServerConfigPath
