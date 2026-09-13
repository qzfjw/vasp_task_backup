[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Server,

    [Parameter(Mandatory)]
    [string]$ProjectName,

    [string[]]$Source = @(),

    [string]$Description = '',

    [string]$BindingPath = (Join-Path (Get-Location).Path '.codex-vasp-project.json'),

    [string]$RulesPath = (Join-Path $PSScriptRoot '..\config\rules\backup-rules.psd1'),

    [string]$RulesOverridePath = '',

    [switch]$CreateRemote,

    [switch]$Force,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\VaspTaskBackup.psm1') -Force
$rules = Import-VaspRuleSet -BasePath $RulesPath -OverridePath $RulesOverridePath -RequiredKeys @('Project', 'Backup')

$nameRegex = [string]$rules.Project.NameRegex
$bindingSchemaVersion = [int]$rules.Project.BindingSchemaVersion

$serverInfo = Get-VaspServer -Server $Server
$serverInfo | Out-Host

Assert-VaspSafeName -Value $ProjectName -Pattern $nameRegex -Label 'Project name'

if ($Source.Count -gt 0) {
    $sources = @($Source | ForEach-Object { ([string]$_).Trim().TrimEnd('/') } | Where-Object { $_ })
} else {
    $sources = @("$($serverInfo.WorkRoot)/$ProjectName")
}
foreach ($relativePath in $sources) {
    Assert-VaspSafeRelativePath -Value $relativePath -Label 'Project source path'
}
if (@($sources | Sort-Object -Unique).Count -ne $sources.Count) {
    throw 'Project source paths must be unique.'
}

$resolvedBindingPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BindingPath)
$bindingExists = Test-Path -LiteralPath $resolvedBindingPath -PathType Leaf
if ($bindingExists -and -not $Force) {
    throw "A project binding already exists: $resolvedBindingPath. Pass -Force only when you intentionally want to replace the current project binding."
}

$plan = [pscustomobject]@{
    Server       = $serverInfo.ServerKey
    SshAlias     = $serverInfo.SshAlias
    Project      = $ProjectName
    Sources      = ($sources -join ', ')
    BindingPath  = $resolvedBindingPath
    Replaced     = $bindingExists
    CreateRemote = [bool]$CreateRemote
    DryRun       = [bool]$DryRun
}

if ($DryRun) {
    Write-Output 'Dry run: the project binding was not written and no remote directories were created.'
    return $plan
}

$binding = [ordered]@{
    schema      = $bindingSchemaVersion
    server      = $serverInfo.ServerKey
    serverName  = $serverInfo.ServerName
    project     = $ProjectName
    workRoot    = $serverInfo.WorkRoot
    description = $Description
    createdAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    sources     = @($sources)
}
$written = Write-VaspProjectBinding -Path $resolvedBindingPath -Binding $binding
Write-Output "Project binding written: $written"

if ($CreateRemote) {
    & (Join-Path $PSScriptRoot 'check_ssh_hosts.ps1') -Server $serverInfo.ServerKey | Out-Host
    $quoted = ConvertTo-BashLiteralList -Values $sources
    $createScript = @'
set -euo pipefail
for rel in __SOURCES__; do
    target="$HOME/$rel"
    if [[ -d "$target" ]]; then
        echo "SOURCE_EXISTS|$rel"
    else
        mkdir -p "$target"
        echo "SOURCE_CREATED|$rel"
    fi
done
'@.Replace('__SOURCES__', $quoted)
    Invoke-VaspRemoteBash -SshAlias $serverInfo.SshAlias -Script $createScript -FailureMessage 'Remote project creation failed' | Out-Host
}

$plan
