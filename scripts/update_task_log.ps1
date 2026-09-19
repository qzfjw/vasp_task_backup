[CmdletBinding()]
param(
    [string]$Server = '',

    [string]$ProjectName = '',

    [string]$TaskId = '',

    [string]$TaskPath = '',

    [string]$BackupDirectory = '',

    [string]$Purpose = '',

    [string]$Conclusion = '',

    [string]$Notes = '',

    [string]$Verification = '',

    [string]$Timestamp = '',

    [string]$LogPath = '',

    [string]$StartPath = (Get-Location).Path,

    [string]$BindingPath = '',

    [string]$RulesPath = (Join-Path $PSScriptRoot '..\config\rules\backup-rules.psd1'),

    [string]$RulesOverridePath = '',

    [string]$ServerConfigPath = '',

    [string]$ResultJsonPath = '',

    [switch]$Yes,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\VaspTaskBackup.psm1') -Force
$rules = Import-VaspRuleSet -BasePath $RulesPath -OverridePath $RulesOverridePath -RequiredKeys @('Project', 'TaskLog')

$bindingFileName = [string]$rules.Project.BindingFileName
$bindingSchemaVersion = [int]$rules.Project.BindingSchemaVersion
$taskIdPrefix = [string]$rules.TaskLog.TaskIdPrefix
$columns = @($rules.TaskLog.Columns | ForEach-Object { [string]$_ })
$logCandidates = @($rules.TaskLog.PathCandidates | ForEach-Object { [string]$_ })
$backupTarget = Get-VaspBackupTarget -ServerConfigPath $ServerConfigPath
if (-not [string]::IsNullOrWhiteSpace($backupTarget.LogPath)) {
    $logCandidates = @($backupTarget.LogPath)
}

foreach ($column in $columns) {
    if ([string]::IsNullOrWhiteSpace($column) -or $column -match "[`r`n|]") {
        throw "Task log rules contain an unsafe column name: $column"
    }
}
foreach ($candidate in $logCandidates) {
    if ($candidate -notmatch '^/[A-Za-z0-9._/-]+$' -or $candidate.Contains('..')) {
        throw "Task log rules contain an unsafe path: $candidate"
    }
}
if ($logCandidates.Count -eq 0) {
    throw 'Task log rules must define at least one entry in TaskLog.PathCandidates.'
}
if ($taskIdPrefix -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Task log rules contain an unsafe task id prefix: $taskIdPrefix"
}

$binding = $null
$resolvedBindingPath = ''
if (-not [string]::IsNullOrWhiteSpace($BindingPath)) {
    $resolvedBindingPath = (Resolve-Path -LiteralPath $BindingPath -ErrorAction Stop).Path
} else {
    $resolvedBindingPath = Find-VaspProjectBinding -StartPath $StartPath -FileName $bindingFileName
}
if ($resolvedBindingPath) {
    $binding = Read-VaspProjectBinding -Path $resolvedBindingPath -ExpectedSchemaVersion $bindingSchemaVersion
}

$resolvedServer = if (-not [string]::IsNullOrWhiteSpace($Server)) { $Server } elseif ($binding) { $binding.Server } else { '' }
if ([string]::IsNullOrWhiteSpace($resolvedServer)) {
    throw 'No server was given and no project binding was found. Select a server explicitly (yang or lan).'
}
$serverInfo = Get-VaspServer -Server $resolvedServer -ServerConfigPath $ServerConfigPath

$resolvedProject = if (-not [string]::IsNullOrWhiteSpace($ProjectName)) { $ProjectName } elseif ($binding) { $binding.Project } else { '' }
if ([string]::IsNullOrWhiteSpace($resolvedProject)) {
    throw 'No project name was given and no project binding was found.'
}

$resolvedTimestamp = ''
if (-not [string]::IsNullOrWhiteSpace($Timestamp)) {
    $resolvedTimestamp = $Timestamp.Trim()
}
if (-not [string]::IsNullOrWhiteSpace($resolvedTimestamp) -and $resolvedTimestamp -notmatch '^[0-9]{8}_[0-9]{6}$') {
    throw "Timestamp must look like yyyyMMdd_HHmmss: $resolvedTimestamp"
}

$resolvedTaskId = ''
if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
    $resolvedTaskId = $TaskId.Trim()
} else {
    if ($resolvedTimestamp) {
        $datePart = $resolvedTimestamp.Split('_')[0]
        $timePart = $resolvedTimestamp.Split('_')[1]
    } else {
        $datePart = (Get-Date).ToString('yyyyMMdd')
        $timePart = (Get-Date).ToString('HHmmss')
    }
    $resolvedTaskId = "$taskIdPrefix-$datePart-$timePart-$resolvedProject"
}
Assert-VaspSafeName -Value $resolvedTaskId -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -Label 'Task id'

$resolvedTaskPath = $TaskPath
if ([string]::IsNullOrWhiteSpace($resolvedTaskPath)) {
    if ($binding -and $binding.Sources.Count -gt 0) {
        $resolvedTaskPath = (@($binding.Sources) | ForEach-Object { "__SRC_HOME__/$_" }) -join '<br>'
    } else {
        $resolvedTaskPath = "__SRC_HOME__/$($serverInfo.WorkRoot)/$resolvedProject"
    }
}
$resolvedBackupDirectory = $BackupDirectory
if (-not [string]::IsNullOrWhiteSpace($resolvedTaskPath)) {
    $taskPathSegments = @($resolvedTaskPath -split '<br>' | ForEach-Object {
        $segment = $_.Trim()
        if ($segment -eq '') { return '' }
        if ($segment.StartsWith('/') -or $segment.StartsWith('__SRC_HOME__/')) { return $segment }
        return "__SRC_HOME__/$segment"
    })
    $resolvedTaskPath = ($taskPathSegments | Where-Object { $_ -ne '' }) -join '<br>'
}
$resolvedVerification = if ([string]::IsNullOrWhiteSpace($Verification)) { '未填写' } else { $Verification }
$resolvedPurpose = if ([string]::IsNullOrWhiteSpace($Purpose)) { '未填写' } else { $Purpose }
$resolvedConclusion = if ([string]::IsNullOrWhiteSpace($Conclusion)) { '未填写' } else { $Conclusion }

$rowCells = @(
    (ConvertTo-VaspMarkdownCell -Value $resolvedTaskId),
    '__LOG_TIMESTAMP__',
    (ConvertTo-VaspMarkdownCell -Value $serverInfo.ServerKey),
    (ConvertTo-VaspMarkdownCell -Value $resolvedTaskPath),
    (ConvertTo-VaspMarkdownCell -Value $resolvedBackupDirectory),
    '__SRC_USER__',
    (ConvertTo-VaspMarkdownCell -Value $resolvedPurpose),
    (ConvertTo-VaspMarkdownCell -Value $resolvedConclusion),
    (ConvertTo-VaspMarkdownCell -Value $resolvedVerification),
    (ConvertTo-VaspMarkdownCell -Value $Notes)
)
$row = '| ' + ($rowCells -join ' | ') + ' |'

$separator = '| ' + (($columns | ForEach-Object { '---' }) -join ' | ') + ' |'
$headerRow = '| ' + ($columns -join ' | ') + ' |'
$headerText = (@(
    [string]$rules.TaskLog.Title,
    '',
    "> $([string]$rules.TaskLog.Intro)",
    '',
    [string]$rules.TaskLog.TableTitle,
    '',
    $headerRow,
    $separator
) -join "`n") + "`n"

$resolvedLogCandidates = @($logCandidates)
if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    $resolvedLogCandidates = @($LogPath)
}
foreach ($candidate in $resolvedLogCandidates) {
    if ($candidate -notmatch '^/[A-Za-z0-9._/-]+$' -or $candidate.Contains('..')) {
        throw "Unsafe task log path: $candidate"
    }
}

if ($binding -and $binding.Server -ne $serverInfo.ServerKey) {
    throw "The project binding selects server '$($binding.Server)' but '$($serverInfo.ServerKey)' was requested."
}

$plan = [pscustomobject]@{
    Server            = $serverInfo.ServerKey
    SshAlias          = $serverInfo.SshAlias
    LogHost           = $backupTarget.HostKey
    LogSshAlias       = $backupTarget.SshAlias
    Project           = $resolvedProject
    TaskId            = $resolvedTaskId
    LogPathCandidates = ($resolvedLogCandidates -join ', ')
    Row               = $row
    BindingPath       = $resolvedBindingPath
}
Write-Output 'Task log plan:'
$plan | Format-List | Out-String | Write-Output

if ($DryRun) {
    Write-Output 'Dry run: the task log was not read or written.'
    if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
        [void](Export-VaspResultJson -Path $ResultJsonPath -Object ([pscustomobject]@{ Status = 'DRY_RUN'; Plan = $plan }))
    }
    return $plan
}

& (Join-Path $PSScriptRoot 'check_ssh_hosts.ps1') -Server $backupTarget.HostKey -ServerConfigPath $ServerConfigPath | Out-Host

if (-not $Yes) {
    Write-Output 'Plan only: the task log was not modified. Re-run with -Yes to write the entry.'
    if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
        [void](Export-VaspResultJson -Path $ResultJsonPath -Object ([pscustomobject]@{ Status = 'PLAN_ONLY'; Plan = $plan }))
    }
    return $plan
}

if ($row.Contains('__SRC_HOME__') -or $row.Contains('__SRC_USER__')) {
    $sourceIdentity = (@(Invoke-VaspRemoteBash -SshAlias $serverInfo.SshAlias -Script 'printf ''%s'' "$(id -un)|$HOME"' -FailureMessage 'Failed to resolve the source server user and HOME directory') -join '').Trim()
    $sourceParts = @($sourceIdentity.Split('|'))
    if ($sourceParts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($sourceParts[0]) -or [string]::IsNullOrWhiteSpace($sourceParts[1])) {
        throw "Could not resolve the source server user and HOME directory (got: $sourceIdentity)."
    }
    $row = $row.Replace('__SRC_USER__', $sourceParts[0]).Replace('__SRC_HOME__', $sourceParts[1])
}

$rowBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($row))
$headerBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($headerText))
$quotedCandidates = ConvertTo-BashLiteralList -Values $resolvedLogCandidates

$logScript = @'
set -euo pipefail

log=''
log_candidates=(__CANDIDATES__)
for candidate in "${log_candidates[@]}"; do
    dir="$(dirname "$candidate")"
    if [[ -e "$candidate" ]]; then
        if [[ -w "$candidate" || -w "$dir" ]]; then log="$candidate"; break; fi
    elif [[ -d "$dir" && -w "$dir" ]]; then
        log="$candidate"; break
    fi
done
if [[ -z "$log" ]]; then
    hint_dir="$(dirname "${log_candidates[0]}")"
    echo "ERROR: no writable task log path among: __CANDIDATES__" >&2
    echo "HINT: ask an administrator to create '$hint_dir' on this server (for example: sudo mkdir -p $hint_dir && sudo chmod 777 $hint_dir)." >&2
    exit 4
fi

lock="${log}.lock"
if ! command -v flock >/dev/null 2>&1; then
    echo "ERROR: flock is required for safe task-log updates." >&2
    exit 4
fi
if ! exec 9>>"$lock" 2>/dev/null; then
    echo "ERROR: could not open task-log lock: $lock" >&2
    exit 4
fi
if ! flock -x 9; then
    echo "ERROR: could not acquire task-log lock: $lock" >&2
    exit 4
fi

server_time="$(date '+%Y-%m-%d %H:%M:%S')"
server_user="$(id -un)"
row="$(printf '%s' '__ROW_B64__' | base64 -d)"
row="${row//__LOG_TIMESTAMP__/$server_time}"
row="${row//__LOG_USER__/$server_user}"
row="${row//__LOG_HOME__/$HOME}"
marker='__MARKER__'
task_id='__TASK_ID__'
tmp="${log}.tmp.$$"
trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
action=''

if [[ -f "$log" ]] && grep -qF "$marker" "$log"; then
    if grep -qF "| ${task_id} |" "$log"; then
        awk -v pattern="| ${task_id} |" -v replacement="$row" 'index($0, pattern) == 1 { print replacement; next } { print }' "$log" > "$tmp"
        action='updated'
    else
        cp "$log" "$tmp"
        if [[ -s "$tmp" ]]; then
            if [[ "$(tail -c 1 "$tmp" | wc -l | tr -d ' ')" == '0' ]]; then printf '\n' >> "$tmp"; fi
        fi
        printf '%s\n' "$row" >> "$tmp"
        action='appended'
    fi
else
    if [[ -f "$log" && -s "$log" ]]; then
        cp "$log" "$tmp"
        if [[ "$(tail -c 1 "$tmp" | wc -l | tr -d ' ')" == '0' ]]; then printf '\n' >> "$tmp"; fi
        printf '\n' >> "$tmp"
    else
        : > "$tmp"
    fi
    printf '%s' '__HEADER_B64__' | base64 -d >> "$tmp"
    printf '%s\n' "$row" >> "$tmp"
    action='appended'
fi

if ! mv -f "$tmp" "$log" 2>/dev/null; then
    echo "ERROR: atomic task-log replacement failed: $log" >&2
    exit 6
fi

if grep -qF "| ${task_id} |" "$log"; then
    echo "LOG_VERIFY|PASS"
else
    echo "LOG_VERIFY|FAIL" >&2
    exit 6
fi

echo "LOG_PATH|$log"
echo "LOG_ACTION|$action"
echo "LOG_TIME|$server_time"
echo "LOG_USER|$server_user"
echo "LOG_TASK_ID|$task_id"
'@.Replace('__CANDIDATES__', $quotedCandidates).Replace('__ROW_B64__', $rowBase64).Replace('__HEADER_B64__', $headerBase64).Replace('__MARKER__', $separator).Replace('__TASK_ID__', $resolvedTaskId)

$logOutput = Invoke-VaspRemoteBash -SshAlias $backupTarget.SshAlias -Script $logScript -FailureMessage 'Task log update failed'
$logOutput | Out-Host

$values = @{}
foreach ($line in $logOutput) {
    if ($line -match '^(?<key>[A-Z_]+)\|(?<value>.*)$') {
        $values[$matches.key] = $matches.value
    }
}
if ($values['LOG_VERIFY'] -ne 'PASS') {
    throw 'Task log update could not be verified.'
}

$result = [pscustomobject]@{
    Status      = 'LOG_UPDATED'
    Server      = $serverInfo.ServerKey
    LogHost     = $backupTarget.HostKey
    Project     = $resolvedProject
    TaskId      = $resolvedTaskId
    LogPath     = $values['LOG_PATH']
    LogAction   = $values['LOG_ACTION']
    LogTime     = $values['LOG_TIME']
    LogUser     = $values['LOG_USER']
    Row         = $row
    BindingPath = $resolvedBindingPath
}

if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
    [void](Export-VaspResultJson -Path $ResultJsonPath -Object $result)
}

$result
