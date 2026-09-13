[CmdletBinding()]
param(
    [string]$Server = '',

    [string]$ProjectName = '',

    [string[]]$Source = @(),

    [string]$BackupRoot = '',

    [string]$Label = '',

    [string]$LocalDirectory = '',

    [string]$TaskId = '',

    [string]$Purpose = '',

    [string]$Conclusion = '',

    [string]$Notes = '',

    [string]$LogPath = '',

    [string]$StartPath = (Get-Location).Path,

    [string]$BindingPath = '',

    [string]$RulesPath = (Join-Path $PSScriptRoot '..\config\rules\backup-rules.psd1'),

    [string]$RulesOverridePath = '',

    [string]$ServerConfigPath = '',

    [switch]$ExcludeLargeFiles,

    [switch]$SkipChecksum,

    [switch]$Yes,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\VaspTaskBackup.psm1') -Force

$backupScript = Join-Path $PSScriptRoot 'backup_current_task.ps1'
$logScript = Join-Path $PSScriptRoot 'update_task_log.ps1'

$backupArguments = @{
    RulesPath        = $RulesPath
    RulesOverridePath = $RulesOverridePath
    StartPath        = $StartPath
    ExcludeLargeFiles = [bool]$ExcludeLargeFiles
    SkipChecksum     = [bool]$SkipChecksum
}
if ($Server) { $backupArguments['Server'] = $Server }
if ($ProjectName) { $backupArguments['ProjectName'] = $ProjectName }
if ($Source.Count -gt 0) { $backupArguments['Source'] = $Source }
if ($BackupRoot) { $backupArguments['BackupRoot'] = $BackupRoot }
if ($Label) { $backupArguments['Label'] = $Label }
if ($LocalDirectory) { $backupArguments['LocalDirectory'] = $LocalDirectory }
if ($BindingPath) { $backupArguments['BindingPath'] = $BindingPath }
if ($ServerConfigPath) { $backupArguments['ServerConfigPath'] = $ServerConfigPath }

if ($DryRun -or -not $Yes) {
    if ($DryRun) { $backupArguments['DryRun'] = $true }
    & $backupScript @backupArguments | Out-Host
    if ($DryRun) {
        Write-Output 'Dry run: the task log was not modified. Re-run with -Yes to back up and write the log entry.'
    } else {
        Write-Output 'Plan only: nothing was copied and the task log was not modified. Re-run with -Yes to back up and write the log entry.'
    }
    return
}

$resultFile = Join-Path ([System.IO.Path]::GetTempPath()) ("vasp-task-backup-{0}.json" -f [guid]::NewGuid().ToString('N'))
try {
    $backupArguments['Yes'] = $true
    $backupArguments['ResultJsonPath'] = $resultFile
    & $backupScript @backupArguments | Out-Host

    if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
        throw 'The backup did not report a structured result; the task log was not updated.'
    }
    $backupResult = Get-Content -LiteralPath $resultFile -Raw -Encoding utf8 | ConvertFrom-Json
    if ([string]$backupResult.Verify -ne 'PASS') {
        throw "The backup did not verify (Verify=$($backupResult.Verify)); the task log was not updated."
    }
    if ([string]$backupResult.LocalVerify -eq 'SHA256_FAILED') {
        throw 'The local project upload failed verification; the task log was not updated.'
    }

    $logArguments = @{
        RulesPath        = $RulesPath
        RulesOverridePath = $RulesOverridePath
        StartPath        = $StartPath
        Yes              = $true
        TaskPath         = [string]$backupResult.SourcePaths
        BackupDirectory  = [string]$backupResult.BackupDirectory
        Verification     = [string]$backupResult.VerificationText
        Timestamp        = [string]$backupResult.Timestamp
    }
    if ($LogPath) { $logArguments['LogPath'] = $LogPath }
    if ($Server) { $logArguments['Server'] = $Server }
    if ($ProjectName) { $logArguments['ProjectName'] = $ProjectName }
    if ($TaskId) { $logArguments['TaskId'] = $TaskId }
    if ($Purpose) { $logArguments['Purpose'] = $Purpose }
    if ($Conclusion) { $logArguments['Conclusion'] = $Conclusion }
    if ($Notes) { $logArguments['Notes'] = $Notes }
    if ($BindingPath) { $logArguments['BindingPath'] = $BindingPath }
    if ($ServerConfigPath) { $logArguments['ServerConfigPath'] = $ServerConfigPath }

    $logResultFile = Join-Path ([System.IO.Path]::GetTempPath()) ("vasp-task-log-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $logArguments['ResultJsonPath'] = $logResultFile
        & $logScript @logArguments | Out-Host
        if (-not (Test-Path -LiteralPath $logResultFile -PathType Leaf)) {
            throw 'The task log update did not report a structured result.'
        }
        $logResult = Get-Content -LiteralPath $logResultFile -Raw -Encoding utf8 | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $logResultFile -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    Status          = 'BACKED_UP_AND_LOGGED'
    Server          = $backupResult.Server
    Project         = $backupResult.Project
    TaskId          = $logResult.TaskId
    BackupDirectory = $backupResult.BackupDirectory
    FileCount       = $backupResult.FileCount
    SizeMB          = $backupResult.SizeMB
    Verify          = $backupResult.Verify
    LocalVerify     = $backupResult.LocalVerify
    TaskLogPath     = $logResult.LogPath
    TaskLogAction   = $logResult.LogAction
}
