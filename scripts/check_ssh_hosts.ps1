[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Server,

    [string]$ServerConfigPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\VaspTaskBackup.psm1') -Force

$serverInfo = Get-VaspServer -Server $Server -ServerConfigPath $ServerConfigPath
$loginOk = Test-VaspSshLogin -SshAlias $serverInfo.SshAlias

$result = [pscustomobject]@{
    Server     = $serverInfo.ServerKey
    SshAlias   = $serverInfo.SshAlias
    HostName   = $serverInfo.HostName
    BatchLogin = $loginOk
    Status     = if ($loginOk) { 'PASS' } else { 'FAIL' }
}
$result

if (-not $loginOk) {
    throw "Batch-mode SSH login failed for $($serverInfo.SshAlias). Check authorized_keys, key passphrase, or ssh-agent."
}
