[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('yang', 'lan')][string]$Server,
    [Parameter(Mandatory)][string[]]$Path,
    [string]$BackupRoot = '',
    [string]$LogPath = '',
    [string]$ServerConfigPath = '',
    [switch]$DeepCheck,
    [switch]$Yes,
    [switch]$DryRun,
    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
if ($Yes -and $DryRun) { throw 'Use either -Yes or -DryRun, not both.' }
$skillRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $skillRoot 'scripts\lib\VaspTaskBackup.psm1') -Force
$serverInfo = Get-VaspServer -Server $Server -ServerConfigPath $ServerConfigPath
$backupTarget = Get-VaspBackupTarget -ServerConfigPath $ServerConfigPath -BackupRoot $BackupRoot
if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = [string]$backupTarget.Root }
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $configPath = if ($ServerConfigPath) { $ServerConfigPath } else { Join-Path $skillRoot 'config\servers.psd1' }
    $config = Import-PowerShellDataFile -LiteralPath $configPath
    $LogPath = [string]$config.Common.Backup.LogPath
}
if ($BackupRoot -notmatch '^/home/[A-Za-z0-9._/-]+$' -or $BackupRoot -eq '/home' -or $BackupRoot.Contains('..')) {
    throw "BackupRoot must be a safe absolute path below /home: $BackupRoot"
}
if ($LogPath -notmatch '^/home/[A-Za-z0-9._/-]+\.xlsx$' -or $LogPath.Contains('..')) {
    throw "LogPath must be an absolute .xlsx path below /home: $LogPath"
}
foreach ($item in $Path) {
    if ($item -notmatch '^/[^/][^\r\n]*$' -or $item.Contains('..') -or $item -match '^/home/bak(/|$)') {
        throw "Source path must be a safe absolute directory outside /home/bak: $item"
    }
}

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments, [string]$FailureMessage)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (exit $LASTEXITCODE)" }
}

function ConvertTo-ShQuote {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Invoke-Remote {
    param([string]$Alias, [string]$Command, [string]$FailureMessage)
    Invoke-Native -Command 'ssh' -Arguments @('-o', 'BatchMode=yes', $Alias, $Command) -FailureMessage $FailureMessage
}

function Send-RemoteFiles {
    param([string]$Alias, [string]$RemoteDirectory, [string[]]$LocalFiles)
    $target = "${Alias}:$RemoteDirectory/"
    $arguments = @('-q') + $LocalFiles + @($target)
    Invoke-Native -Command 'scp' -Arguments $arguments -FailureMessage "Failed to upload helper files to $Alias"
}

function Receive-RemoteFile {
    param([string]$Alias, [string]$RemotePath, [string]$LocalPath)
    Invoke-Native -Command 'scp' -Arguments @('-q', "${Alias}:$RemotePath", $LocalPath) -FailureMessage "Failed to download $RemotePath from $Alias"
}

function Copy-RemoteToRemote {
    param([string]$SourceAlias, [string[]]$SourcePaths, [string]$TargetAlias, [string]$TargetDirectory)
    $target = "${TargetAlias}:$TargetDirectory/"
    $arguments = @('-3', '-q') + @($SourcePaths | ForEach-Object { "${SourceAlias}:$_" }) + @($target)
    Invoke-Native -Command 'scp' -Arguments $arguments -FailureMessage "Failed to transfer archive from $SourceAlias to $TargetAlias"
}

function New-RemoteRequest {
    param([bool]$Execute)
    return [ordered]@{
        server = $Server
        paths = @($Path)
        backup_root = $BackupRoot
        log_path = $LogPath
        index_path = "$BackupRoot/.vasp_task_backup/index.json"
        execute = $Execute
        deep_check = [bool]$DeepCheck
    }
}

function ConvertTo-Base64Json {
    param($Object)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

$helperFiles = @(
    (Join-Path $PSScriptRoot 'vasp_task_backup.py'),
    (Join-Path $PSScriptRoot 'vasp_backup_common.py'),
    (Join-Path $PSScriptRoot 'vasp_backup_scan.py'),
    (Join-Path $PSScriptRoot 'vasp_backup_store.py'),
    (Join-Path $PSScriptRoot 'vasp_xlsx_log.py')
)
foreach ($helper in $helperFiles) {
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw "Missing helper file: $helper" }
}

$token = [Guid]::NewGuid().ToString('N')
$sourceAlias = $serverInfo.SshAlias
$backupAlias = $backupTarget.SshAlias
$sourceDir = "/tmp/codex-vasp-backup-source-$token"
$backupDir = "/tmp/codex-vasp-backup-target-$token"
$localDir = Join-Path ([System.IO.Path]::GetTempPath()) "codex-vasp-backup-$token"
$execute = [bool]($Yes -and -not $DryRun)
$crossHost = $sourceAlias -ne $backupAlias
$request = New-RemoteRequest -Execute $execute
$requestB64 = ConvertTo-Base64Json -Object $request
$cleanupDirs = @()
try {
    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    Invoke-Remote -Alias $backupAlias -Command "mkdir -p $(ConvertTo-ShQuote $backupDir)" -FailureMessage 'Failed to create remote backup work directory'
    $cleanupDirs += @{ Alias = $backupAlias; Path = $backupDir }
    Send-RemoteFiles -Alias $backupAlias -RemoteDirectory $backupDir -LocalFiles $helperFiles
    $backupPython = ConvertTo-ShQuote "$backupDir/vasp_task_backup.py"
    $requestArg = ConvertTo-ShQuote $requestB64

    if (-not $crossHost) {
        $command = "python3 $backupPython run --request-b64 $requestArg"
        $output = @(& ssh -o BatchMode=yes $backupAlias $command 2>&1)
        $exitCode = $LASTEXITCODE
        $text = $output -join [Environment]::NewLine
        if ($exitCode -ne 0) { throw "VASP backup failed on ${backupAlias}:`n$text" }
        $text | Write-Output
        if ($ReportPath) { [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath), $text + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false))) }
        return
    }

    Invoke-Remote -Alias $sourceAlias -Command "mkdir -p $(ConvertTo-ShQuote $sourceDir)" -FailureMessage 'Failed to create source work directory'
    $cleanupDirs += @{ Alias = $sourceAlias; Path = $sourceDir }
    Send-RemoteFiles -Alias $sourceAlias -RemoteDirectory $sourceDir -LocalFiles $helperFiles
    $sourcePython = ConvertTo-ShQuote "$sourceDir/vasp_task_backup.py"
    $remoteIndex = "$backupDir/index.json"
    $localIndex = Join-Path $localDir 'index.json'
    $sourceIndex = "$sourceDir/index.json"
    Invoke-Remote -Alias $backupAlias -Command "python3 $backupPython export-index --request-b64 $requestArg --output $(ConvertTo-ShQuote $remoteIndex)" -FailureMessage 'Failed to export backup index'
    Receive-RemoteFile -Alias $backupAlias -RemotePath $remoteIndex -LocalPath $localIndex
    Invoke-Native -Command 'scp' -Arguments @('-q', $localIndex, "${sourceAlias}:$sourceIndex") -FailureMessage 'Failed to upload backup index to source server'
    $sourceRequest = [ordered]@{}
    foreach ($key in $request.Keys) { $sourceRequest[$key] = $request[$key] }
    $sourceRequest['index_path'] = $sourceIndex
    $sourceRequest['execute'] = $false
    $sourceRequestB64 = ConvertTo-Base64Json -Object $sourceRequest
    $sourceRequestArg = ConvertTo-ShQuote $sourceRequestB64

    $inventoryPath = "$sourceDir/inventory.json"
    $summaryPath = "$sourceDir/summary.json"
    $summaryCommand = "python3 $sourcePython inventory --request-b64 $sourceRequestArg --output $(ConvertTo-ShQuote $inventoryPath) --summary $(ConvertTo-ShQuote $summaryPath)"
    Invoke-Remote -Alias $sourceAlias -Command $summaryCommand -FailureMessage 'Failed to scan VASP tasks'
    $localSummary = Join-Path $localDir 'summary.json'
    Receive-RemoteFile -Alias $sourceAlias -RemotePath $summaryPath -LocalPath $localSummary
    $summary = Get-Content -LiteralPath $localSummary -Raw -Encoding utf8 | ConvertFrom-Json
    $backupSummary = "$backupDir/summary.json"
    $backupActions = "$backupDir/actions.json"
    Invoke-Native -Command 'scp' -Arguments @('-q', $localSummary, "${backupAlias}:$backupSummary") -FailureMessage 'Failed to upload inventory summary to backup host'
    $checkCommand = "python3 $backupPython check-targets --request-b64 $requestArg --summary $(ConvertTo-ShQuote $backupSummary) --output $(ConvertTo-ShQuote $backupActions)"
    Invoke-Remote -Alias $backupAlias -Command $checkCommand -FailureMessage 'Failed to verify existing backup destinations'
    $localActions = Join-Path $localDir 'actions.json'
    Receive-RemoteFile -Alias $backupAlias -RemotePath $backupActions -LocalPath $localActions
    $actionResult = Get-Content -LiteralPath $localActions -Raw -Encoding utf8 | ConvertFrom-Json
    $summary.actions = @($actionResult.actions)
    $summary | Add-Member -Force -NotePropertyName repairs -NotePropertyValue @($actionResult.repairs)

    if (-not $execute) {
        $summary | ConvertTo-Json -Depth 10
        if ($ReportPath) { Copy-Item -LiteralPath $localSummary -Destination $ReportPath -Force }
        return
    }

    $counter = 0
    foreach ($action in @($actionResult.actions)) {
        $counter++
        $archivePath = "$sourceDir/task-$counter.tar"
        $manifestPath = "$sourceDir/task-$counter.json"
        $packCommand = "python3 $sourcePython pack --request-b64 $sourceRequestArg --inventory $(ConvertTo-ShQuote $inventoryPath) --task $(ConvertTo-ShQuote ([string]$action.path)) --destination $(ConvertTo-ShQuote ([string]$action.destination)) --archive $(ConvertTo-ShQuote $archivePath) --manifest $(ConvertTo-ShQuote $manifestPath)"
        Invoke-Remote -Alias $sourceAlias -Command $packCommand -FailureMessage "Failed to archive $($action.path)"
        $backupArchive = "$backupDir/task-$counter.tar"
        $backupManifest = "$backupDir/task-$counter.json"
        Copy-RemoteToRemote -SourceAlias $sourceAlias -SourcePaths @($archivePath, $manifestPath) -TargetAlias $backupAlias -TargetDirectory $backupDir
        $applyCommand = "python3 $backupPython apply --request-b64 $requestArg --archive $(ConvertTo-ShQuote $backupArchive) --manifest $(ConvertTo-ShQuote $backupManifest)"
        Invoke-Remote -Alias $backupAlias -Command $applyCommand -FailureMessage "Failed to install backup for $($action.path)"
    }

    $recordsPath = "$sourceDir/log-records.json"
    $recordsCommand = "python3 $sourcePython log-records --inventory $(ConvertTo-ShQuote $inventoryPath) --output $(ConvertTo-ShQuote $recordsPath)"
    Invoke-Remote -Alias $sourceAlias -Command $recordsCommand -FailureMessage 'Failed to export VaspLog records'
    $backupRecords = "$backupDir/log-records.json"
    Receive-RemoteFile -Alias $sourceAlias -RemotePath $recordsPath -LocalPath (Join-Path $localDir 'log-records.json')
    Invoke-Native -Command 'scp' -Arguments @('-q', (Join-Path $localDir 'log-records.json'), "${backupAlias}:$backupRecords") -FailureMessage 'Failed to upload VaspLog records to backup host'
    $logCommand = "python3 $backupPython update-log --request-b64 $requestArg --records $(ConvertTo-ShQuote $backupRecords)"
    Invoke-Remote -Alias $backupAlias -Command $logCommand -FailureMessage 'Failed to update VaspLog.xlsx'
    Invoke-Remote -Alias $backupAlias -Command "python3 $backupPython compact-index --request-b64 $requestArg" -FailureMessage 'Failed to compact backup index'

    $result = [ordered]@{
        status = 'COMPLETED'
        server = $Server
        backup_host = $backupTarget.HostKey
        paths = @($Path)
        complete_count = [int]$summary.complete_count
        incomplete_count = [int]$summary.incomplete_count
        new_count = [int]$summary.counts.new
        changed_count = [int]$summary.counts.changed
        unchanged_count = [int]$summary.counts.unchanged
        repaired_count = @($actionResult.repairs).Count
        transferred_count = $counter
        log_path = $LogPath
    }
    $result | ConvertTo-Json -Depth 8
    if ($ReportPath) {
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    }
}
finally {
    foreach ($item in $cleanupDirs) {
        if ($item.Path -notmatch '^/tmp/codex-vasp-backup-(source|target)-[0-9a-f]{32}$') { continue }
        & ssh -o BatchMode=yes $item.Alias "rm -rf -- $(ConvertTo-ShQuote $item.Path)" 2>$null
    }
    if (Test-Path -LiteralPath $localDir) {
        $resolvedLocal = (Resolve-Path -LiteralPath $localDir).Path
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedLocal.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedLocal) -match '^codex-vasp-backup-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $resolvedLocal -Recurse -Force
        }
    }
}
