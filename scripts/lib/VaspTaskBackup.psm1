Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VaspField {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = ''
    )

    if ($null -eq $InputObject) {
        return $Default
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name) -and $null -ne $InputObject[$Name]) {
            return $InputObject[$Name]
        }
        return $Default
    }
    if ($InputObject.PSObject.Properties.Name -contains $Name) {
        $value = $InputObject.$Name
        if ($null -ne $value) {
            return $value
        }
    }
    return $Default
}

function Copy-VaspRuleValue {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $copy[$key] = Copy-VaspRuleValue -Value $Value[$key]
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { Copy-VaspRuleValue -Value $_ })
    }
    return $Value
}

function Merge-VaspRuleMap {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Base,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Override
    )

    $merged = Copy-VaspRuleValue -Value $Base
    foreach ($key in $Override.Keys) {
        if (
            $merged.Contains($key) -and
            $merged[$key] -is [System.Collections.IDictionary] -and
            $Override[$key] -is [System.Collections.IDictionary]
        ) {
            $merged[$key] = Merge-VaspRuleMap -Base $merged[$key] -Override $Override[$key]
        } else {
            $merged[$key] = Copy-VaspRuleValue -Value $Override[$key]
        }
    }
    return $merged
}

function Import-VaspRuleSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [string]$OverridePath = '',
        [int]$ExpectedSchemaVersion = 1,
        [string[]]$RequiredKeys = @()
    )

    if (-not (Test-Path -LiteralPath $BasePath -PathType Leaf)) {
        throw "Rule file does not exist: $BasePath"
    }
    $resolvedBasePath = (Resolve-Path -LiteralPath $BasePath).Path
    $rules = Import-PowerShellDataFile -LiteralPath $resolvedBasePath
    if ([int]$rules.SchemaVersion -ne $ExpectedSchemaVersion) {
        throw "Unsupported rule schema in $resolvedBasePath. Expected $ExpectedSchemaVersion, found $($rules.SchemaVersion)."
    }

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        if (-not (Test-Path -LiteralPath $OverridePath -PathType Leaf)) {
            throw "Rule override file does not exist: $OverridePath"
        }
        $resolvedOverridePath = (Resolve-Path -LiteralPath $OverridePath).Path
        $override = Import-PowerShellDataFile -LiteralPath $resolvedOverridePath
        if ($override.Contains('SchemaVersion') -and [int]$override.SchemaVersion -ne $ExpectedSchemaVersion) {
            throw "Unsupported override schema in $resolvedOverridePath."
        }
        $rules = Merge-VaspRuleMap -Base $rules -Override $override
    }

    foreach ($key in $RequiredKeys) {
        if (-not $rules.Contains($key) -or $null -eq $rules[$key]) {
            throw "Required rule section '$key' is missing from $resolvedBasePath."
        }
    }
    return $rules
}

function Assert-VaspSafeName {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Value -notmatch $Pattern) {
        throw "$Label is not a valid name: $Value (expected pattern: $Pattern)"
    }
}

function Assert-VaspSafeRelativePath {
    param(
        [Parameter(Mandatory)][string]$Value,
        [string]$Label = 'Path'
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value -notmatch '^[A-Za-z0-9._/-]+$' -or
        $Value.StartsWith('/') -or
        $Value.Contains('..')
    ) {
        throw "$Label must be a safe HOME-relative path without '..': $Value"
    }
}

function ConvertTo-BashLiteralList {
    param([string[]]$Values = @())

    $list = @($Values | Where-Object { $null -ne $_ -and ([string]$_).Length -gt 0 })
    if ($list.Count -eq 0) {
        return ''
    }
    return (($list | ForEach-Object { "'$_'" }) -join ' ')
}

function Resolve-VaspServerConfigPath {
    param([string]$ServerConfigPath = '')

    if (-not [string]::IsNullOrWhiteSpace($ServerConfigPath)) {
        return $ServerConfigPath
    }
    $skillRoot = Join-Path $PSScriptRoot '..\..'
    $localConfig = Join-Path $skillRoot 'config\servers.local.psd1'
    $sharedConfig = Join-Path $skillRoot 'config\servers.psd1'
    if (Test-Path -LiteralPath $localConfig -PathType Leaf) {
        return $localConfig
    }
    return $sharedConfig
}

function Get-VaspServerConfig {
    param([string]$ServerConfigPath = '')

    $resolvedConfigPath = Resolve-VaspServerConfigPath -ServerConfigPath $ServerConfigPath
    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "Server config file does not exist: $resolvedConfigPath"
    }
    $resolvedConfigPath = (Resolve-Path -LiteralPath $resolvedConfigPath).Path
    return [pscustomobject]@{
        Path   = $resolvedConfigPath
        Config = Import-PowerShellDataFile -LiteralPath $resolvedConfigPath
    }
}

function Get-VaspBackupTarget {
    [CmdletBinding()]
    param(
        [string]$ServerConfigPath = '',
        [string]$BackupHost = '',
        [string]$BackupRoot = '',
        [string]$BackupLogPath = ''
    )

    $serverConfigFile = Get-VaspServerConfig -ServerConfigPath $ServerConfigPath
    $common = if ($serverConfigFile.Config.Contains('Common')) { $serverConfigFile.Config.Common } else { @{} }
    $settings = Get-VaspField -InputObject $common -Name 'Backup' -Default @{}

    $hostKey = if (-not [string]::IsNullOrWhiteSpace($BackupHost)) {
        $BackupHost
    } else {
        [string](Get-VaspField -InputObject $settings -Name 'Host' -Default 'yang')
    }
    if ([string]::IsNullOrWhiteSpace($hostKey)) {
        throw 'The backup host is not configured (Common.Backup.Host).'
    }

    $serverInfo = Get-VaspServer -Server $hostKey -ServerConfigPath $serverConfigFile.Path
    $root = if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot
    } else {
        [string](Get-VaspField -InputObject $settings -Name 'Root' -Default '')
    }
    $logPath = if (-not [string]::IsNullOrWhiteSpace($BackupLogPath)) {
        $BackupLogPath
    } else {
        [string](Get-VaspField -InputObject $settings -Name 'LogPath' -Default '')
    }

    return [pscustomobject]@{
        HostKey    = $serverInfo.ServerKey
        ServerName = $serverInfo.ServerName
        SshAlias   = $serverInfo.SshAlias
        HostName   = $serverInfo.HostName
        Root       = $root
        LogPath    = $logPath
        ConfigPath = $serverConfigFile.Path
    }
}

function Get-VaspServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [string]$ServerConfigPath = ''
    )

    $serverConfigFile = Get-VaspServerConfig -ServerConfigPath $ServerConfigPath
    $resolvedConfigPath = $serverConfigFile.Path
    $config = $serverConfigFile.Config
    if (-not $config.Servers -or $config.Servers.Count -eq 0) {
        throw "No servers are defined in: $resolvedConfigPath"
    }

    $matchingKeys = @(
        $config.Servers.Keys | Where-Object {
            $_ -ieq $Server -or [string](Get-VaspField -InputObject $config.Servers[$_] -Name 'SshAlias') -ieq $Server
        }
    )
    if ($matchingKeys.Count -ne 1) {
        $available = @($config.Servers.Keys | Sort-Object) -join ', '
        throw "Unknown server '$Server'. Available servers: $available"
    }

    $serverKey = [string]$matchingKeys[0]
    $serverConfig = $config.Servers[$serverKey]
    $common = if ($config.Contains('Common')) { $config.Common } else { @{} }
    $settings = @{}
    foreach ($key in $common.Keys) {
        $settings[$key] = $common[$key]
    }
    $serverSettings = Get-VaspField -InputObject $serverConfig -Name 'Settings' -Default @{}
    foreach ($key in $serverSettings.Keys) {
        $settings[$key] = $serverSettings[$key]
    }

    if ([string]::IsNullOrWhiteSpace([string](Get-VaspField -InputObject $serverConfig -Name 'SshAlias'))) {
        throw "SshAlias is missing for server '$serverKey'."
    }
    $workRoot = [string](Get-VaspField -InputObject $settings -Name 'WorkRoot')
    if ([string]::IsNullOrWhiteSpace($workRoot)) {
        throw "Setting 'WorkRoot' is missing for server '$serverKey'."
    }

    $env:VASP_SERVER_KEY = $serverKey
    $env:VASP_SERVER_NAME = [string](Get-VaspField -InputObject $serverConfig -Name 'DisplayName' -Default $serverKey)
    $env:VASP_SSH_ALIAS = [string](Get-VaspField -InputObject $serverConfig -Name 'SshAlias')
    $env:VASP_HOST_NAME = [string](Get-VaspField -InputObject $serverConfig -Name 'HostName')
    $env:VASP_WORK_ROOT = $workRoot

    return [pscustomobject]@{
        ServerKey  = $serverKey
        ServerName = $env:VASP_SERVER_NAME
        SshAlias   = $env:VASP_SSH_ALIAS
        HostName   = $env:VASP_HOST_NAME
        WorkRoot   = $env:VASP_WORK_ROOT
        ConfigPath = $resolvedConfigPath
    }
}

function Test-VaspSshLogin {
    param([Parameter(Mandatory)][string]$SshAlias)

    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw 'OpenSSH client ssh.exe was not found.'
    }
    $output = @(& ssh -o BatchMode=yes -o ConnectTimeout=10 $SshAlias 'printf CODEX_SSH_READY' 2>&1)
    return ($LASTEXITCODE -eq 0 -and (($output -join '') -match 'CODEX_SSH_READY'))
}

function Invoke-VaspRemoteBash {
    param(
        [Parameter(Mandatory)][string]$SshAlias,
        [Parameter(Mandatory)][string]$Script,
        [string]$FailureMessage = 'Remote command failed'
    )

    $normalized = $Script.Replace("`r`n", "`n").Replace("`r", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    $output = @(& ssh -o BatchMode=yes $SshAlias "echo $encoded | base64 -d | bash" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage on ${SshAlias}:`n$($output -join "`n")"
    }
    return $output
}

function Find-VaspProjectBinding {
    param(
        [Parameter(Mandatory)][string]$StartPath,
        [Parameter(Mandatory)][string]$FileName
    )

    $directory = (Resolve-Path -LiteralPath $StartPath).Path
    for ($level = 0; $level -lt 12; $level++) {
        $candidate = Join-Path $directory $FileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        $parent = Split-Path -Parent $directory
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $directory) {
            break
        }
        $directory = $parent
    }
    return ''
}

function Read-VaspProjectBinding {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$ExpectedSchemaVersion = 1
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Project binding file does not exist: $Path"
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $binding = Get-Content -LiteralPath $resolvedPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([int]$binding.schema -ne $ExpectedSchemaVersion) {
        throw "Unsupported project binding schema in ${resolvedPath}: $($binding.schema)"
    }
    return [pscustomobject]@{
        Path        = $resolvedPath
        Server      = [string](Get-VaspField -InputObject $binding -Name 'server')
        Project     = [string](Get-VaspField -InputObject $binding -Name 'project')
        WorkRoot    = [string](Get-VaspField -InputObject $binding -Name 'workRoot')
        Sources     = @((Get-VaspField -InputObject $binding -Name 'sources' -Default @()) | ForEach-Object { [string]$_ })
        CreatedAt   = [string](Get-VaspField -InputObject $binding -Name 'createdAt')
        Description = [string](Get-VaspField -InputObject $binding -Name 'description')
    }
}

function Write-VaspProjectBinding {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Binding
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $json = $Binding | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($resolvedPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    return $resolvedPath
}

function ConvertTo-VaspMarkdownCell {
    param([string]$Value = '')

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    $text = $Value.Replace("`r`n", "`n").Replace("`r", "`n")
    $text = $text.Replace('|', '\|')
    $text = $text.Replace("`n", '<br>')
    return $text.Trim()
}

function Export-VaspResultJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $json = $Object | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($resolvedPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    return $resolvedPath
}

Export-ModuleMember -Function @(
    'Import-VaspRuleSet',
    'Merge-VaspRuleMap',
    'Get-VaspField',
    'Assert-VaspSafeName',
    'Assert-VaspSafeRelativePath',
    'ConvertTo-BashLiteralList',
    'Get-VaspServerConfig',
    'Get-VaspBackupTarget',
    'Get-VaspServer',
    'Test-VaspSshLogin',
    'Invoke-VaspRemoteBash',
    'Find-VaspProjectBinding',
    'Read-VaspProjectBinding',
    'Write-VaspProjectBinding',
    'ConvertTo-VaspMarkdownCell',
    'Export-VaspResultJson'
)
