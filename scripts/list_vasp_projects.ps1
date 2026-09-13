[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Server,

    [string]$StartPath = (Get-Location).Path,

    [string]$BindingPath = '',

    [string]$RulesPath = (Join-Path $PSScriptRoot '..\config\rules\backup-rules.psd1'),

    [string]$RulesOverridePath = '',

    [string]$ServerConfigPath = '',

    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\VaspTaskBackup.psm1') -Force
$rules = Import-VaspRuleSet -BasePath $RulesPath -OverridePath $RulesOverridePath -RequiredKeys @('Project', 'Backup', 'TaskLog')

$bindingFileName = [string]$rules.Project.BindingFileName
$backupRoots = @($rules.Backup.RootCandidates | ForEach-Object { [string]$_ })
$logCandidates = @($rules.TaskLog.PathCandidates | ForEach-Object { [string]$_ })
if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    $logCandidates = @($LogPath)
}

$serverInfo = Get-VaspServer -Server $Server -ServerConfigPath $ServerConfigPath
$serverInfo | Out-Host
$backupTarget = Get-VaspBackupTarget -ServerConfigPath $ServerConfigPath -BackupLogPath $LogPath
if (-not [string]::IsNullOrWhiteSpace($backupTarget.Root)) {
    $backupRoots = @($backupTarget.Root)
}
if (-not [string]::IsNullOrWhiteSpace($backupTarget.LogPath)) {
    $logCandidates = @($backupTarget.LogPath)
}

$boundProject = ''
$resolvedBindingPath = if ($BindingPath) { (Resolve-Path -LiteralPath $BindingPath -ErrorAction Stop).Path } else { Find-VaspProjectBinding -StartPath $StartPath -FileName $bindingFileName }
if ($resolvedBindingPath) {
    $binding = Read-VaspProjectBinding -Path $resolvedBindingPath
    $boundProject = $binding.Project
}

& (Join-Path $PSScriptRoot 'check_ssh_hosts.ps1') -Server $serverInfo.ServerKey -ServerConfigPath $ServerConfigPath | Out-Host
if ($backupTarget.HostKey -ne $serverInfo.ServerKey) {
    & (Join-Path $PSScriptRoot 'check_ssh_hosts.ps1') -Server $backupTarget.HostKey -ServerConfigPath $ServerConfigPath | Out-Host
}

$projectListScript = @'
set -u
work_root="$HOME/__WORK_ROOT__"
echo "WORK_ROOT|$work_root"
if [[ -d "$work_root" ]]; then
    for dir in "$work_root"/*/; do
        [[ -d "$dir" ]] || continue
        name="$(basename "$dir")"
        modified="$(date -r "$dir" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "$dir" | cut -d'.' -f1)"
        files="$(find "$dir" -type f | wc -l | tr -d ' ')"
        bytes="$(find "$dir" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
        echo "PROJECT|$name|$modified|$files|$bytes"
    done
fi
'@.Replace('__WORK_ROOT__', $serverInfo.WorkRoot)

$backupListScript = @'
set -u
for root in __ROOTS__; do
    if [[ -d "$root" ]]; then
        for dir in "$root"/*/; do
            [[ -d "$dir" ]] || continue
            name="$(basename "$dir")"
            modified="$(date -r "$dir" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "$dir" | cut -d'.' -f1)"
            files="$(find "$dir" -type f | wc -l | tr -d ' ')"
            bytes="$(find "$dir" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
            runs=0
            for run in "$dir"*/; do
                [[ -d "$run" ]] || continue
                runname="$(basename "$run")"
                [[ "$runname" =~ ^[0-9]{8}_[0-9]{6} ]] || continue
                runs=$((runs + 1))
                run_modified="$(date -r "$run" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "$run" | cut -d'.' -f1)"
                run_files="$(find "$run" -type f | wc -l | tr -d ' ')"
                run_bytes="$(find "$run" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
                echo "BACKUP_RUN|$root|$name|$runname|$run_modified|$run_files|$run_bytes"
            done
            echo "BACKUP|$root|$name|$modified|$files|$bytes|$runs"
        done
    fi
done
for candidate in __LOGS__; do
    if [[ -f "$candidate" ]]; then
        echo "TASKLOG|$candidate|$(stat -c '%s' "$candidate" 2>/dev/null || echo 0)"
    fi
done
'@.Replace('__ROOTS__', (ConvertTo-BashLiteralList -Values $backupRoots)).Replace('__LOGS__', (ConvertTo-BashLiteralList -Values $logCandidates))

$projectListing = Invoke-VaspRemoteBash -SshAlias $serverInfo.SshAlias -Script $projectListScript -FailureMessage "Remote project listing failed on $($serverInfo.ServerKey)"
$backupListing = Invoke-VaspRemoteBash -SshAlias $backupTarget.SshAlias -Script $backupListScript -FailureMessage "Remote backup listing failed on $($backupTarget.HostKey)"
$listing = @($projectListing) + @($backupListing)

$projectRows = @()
$backupRows = @()
$backupRunRows = @()
$logRows = @()
foreach ($line in $listing) {
    if ($line -match '^PROJECT\|(?<name>[^|]+)\|(?<modified>[^|]*)\|(?<files>\d+)\|(?<bytes>\d+)$') {
        $projectRows += [pscustomobject]@{
            Project  = $matches.name
            Modified = $matches.modified
            Files    = [int64]$matches.files
            SizeMB   = [math]::Round(([int64]$matches.bytes) / 1MB, 2)
            Current  = ($matches.name -eq $boundProject)
        }
    }
    if ($line -match '^BACKUP\|(?<root>[^|]+)\|(?<name>[^|]+)\|(?<modified>[^|]*)\|(?<files>\d+)\|(?<bytes>\d+)\|(?<runs>\d+)$') {
        $backupRows += [pscustomobject]@{
            ProjectDirectory = $matches.name
            Root             = $matches.root
            Runs             = [int]$matches.runs
            Modified         = $matches.modified
            Files            = [int64]$matches.files
            SizeMB           = [math]::Round(([int64]$matches.bytes) / 1MB, 2)
        }
    }
    if ($line -match '^BACKUP_RUN\|(?<root>[^|]+)\|(?<project>[^|]+)\|(?<run>[^|]+)\|(?<modified>[^|]*)\|(?<files>\d+)\|(?<bytes>\d+)$') {
        $backupRunRows += [pscustomobject]@{
            Project  = $matches.project
            Run      = $matches.run
            Root     = $matches.root
            Modified = $matches.modified
            Files    = [int64]$matches.files
            SizeMB   = [math]::Round(([int64]$matches.bytes) / 1MB, 2)
        }
    }
    if ($line -match '^TASKLOG\|(?<path>[^|]+)\|(?<size>\d+)$') {
        $logRows += [pscustomobject]@{ LogPath = $matches.path; Bytes = [int64]$matches.size }
    }
}

Write-Output "Server: $($serverInfo.ServerKey)  Work root: ~/$($serverInfo.WorkRoot)"
Write-Output "Backup host: $($backupTarget.HostKey)  Backup root: $($backupRoots -join ', ')  Task log: $($logCandidates -join ', ')"
Write-Output "Current project binding: $(if ($boundProject) { "$boundProject ($resolvedBindingPath)" } else { 'none' })"
Write-Output ''
Write-Output 'Remote task directories:'
$projectRows | Sort-Object Modified -Descending | Format-Table -AutoSize | Out-String | Write-Output
Write-Output 'Project backup folders (one folder per project, each backup is a subfolder):'
$backupRows | Sort-Object Modified -Descending | Format-Table ProjectDirectory, Root, Runs, Modified, Files, SizeMB -AutoSize | Out-String | Write-Output
Write-Output 'Backup runs:'
$backupRunRows | Sort-Object Modified -Descending | Format-Table Project, Run, Modified, Files, SizeMB -AutoSize | Out-String | Write-Output
Write-Output 'Task log files:'
$logRows | Format-Table -AutoSize | Out-String | Write-Output

[pscustomobject]@{
    Server       = $serverInfo.ServerKey
    BackupHost   = $backupTarget.HostKey
    BoundProject = $boundProject
    BindingPath  = $resolvedBindingPath
    ProjectCount = $projectRows.Count
    BackupCount  = $backupRows.Count
    BackupRunCount = $backupRunRows.Count
    TaskLogs     = $logRows
    Projects     = $projectRows
    Backups      = $backupRows
    BackupRuns   = $backupRunRows
}
