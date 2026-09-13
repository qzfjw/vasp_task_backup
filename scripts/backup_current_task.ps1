[CmdletBinding()]
param(
    [string]$Server = '',

    [string]$ProjectName = '',

    [string[]]$Source = @(),

    [string]$BackupRoot = '',

    [string]$Label = '',

    [string]$LocalDirectory = '',

    [string]$StartPath = (Get-Location).Path,

    [string]$BindingPath = '',

    [string]$RulesPath = (Join-Path $PSScriptRoot '..\config\rules\backup-rules.psd1'),

    [string]$RulesOverridePath = '',

    [string]$ServerConfigPath = '',

    [string]$ResultJsonPath = '',

    [switch]$ExcludeLargeFiles,

    [switch]$SkipChecksum,

    [switch]$Yes,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\VaspTaskBackup.psm1') -Force
$rules = Import-VaspRuleSet -BasePath $RulesPath -OverridePath $RulesOverridePath -RequiredKeys @('Project', 'Backup')

$bindingFileName = [string]$rules.Project.BindingFileName
$bindingSchemaVersion = [int]$rules.Project.BindingSchemaVersion
$nameRegex = [string]$rules.Project.NameRegex
$rootCandidates = @($rules.Backup.RootCandidates | ForEach-Object { [string]$_ })
$timestampFormat = [string]$rules.Backup.TimestampFormat
$largeFileNames = @($rules.Backup.LargeFileNames | ForEach-Object { [string]$_ })
$manifestName = [string]$rules.Backup.ManifestName
$checksumName = [string]$rules.Backup.ChecksumFileName
$localSubdirectory = [string]$rules.Backup.LocalSubdirectory
$maxShaBytes = [int64]$rules.Backup.Sha256MaxSizeMB * 1MB

foreach ($fileName in @($manifestName, $checksumName, $localSubdirectory) + $largeFileNames) {
    if ($fileName -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Backup rules contain an unsafe file or directory name: $fileName"
    }
}
if ($timestampFormat -notmatch '^[A-Za-z0-9%_.:+-]+$') {
    throw "Backup rules contain an unsafe timestamp format: $timestampFormat"
}
foreach ($candidate in $rootCandidates) {
    if ($candidate -notmatch '^/[A-Za-z0-9._/-]+$' -or $candidate.Contains('..')) {
        throw "Backup rules contain an unsafe backup root: $candidate"
    }
}
if ($rootCandidates.Count -eq 0) {
    throw 'Backup rules must define at least one entry in Backup.RootCandidates.'
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
    Assert-VaspSafeName -Value $binding.Project -Pattern $nameRegex -Label 'Bound project name'
}

$resolvedServer = if (-not [string]::IsNullOrWhiteSpace($Server)) { $Server } elseif ($binding) { $binding.Server } else { '' }
if ([string]::IsNullOrWhiteSpace($resolvedServer)) {
    throw 'No server was given and no project binding was found. Select a server explicitly (yang or lan), or run scripts/new_vasp_project.ps1 first.'
}

$resolvedProject = if (-not [string]::IsNullOrWhiteSpace($ProjectName)) { $ProjectName } else { '' }
if ($binding -and $resolvedProject -and $resolvedProject -ne $binding.Project) {
    throw "The current project binding is '$($binding.Project)' but '$resolvedProject' was requested. Back up the bound project, or create a new binding after confirming with the user."
}
if (-not $resolvedProject -and $binding) {
    $resolvedProject = $binding.Project
}
if ([string]::IsNullOrWhiteSpace($resolvedProject)) {
    throw 'No project name was given and no project binding was found. Each task must own a project before it can be backed up.'
}
Assert-VaspSafeName -Value $resolvedProject -Pattern $nameRegex -Label 'Project name'

$serverInfo = Get-VaspServer -Server $resolvedServer -ServerConfigPath $ServerConfigPath
$backupTarget = Get-VaspBackupTarget -ServerConfigPath $ServerConfigPath -BackupRoot $BackupRoot
if ($binding -and $binding.WorkRoot -cne $serverInfo.WorkRoot) {
    throw "Bound work root '$($binding.WorkRoot)' does not match the selected server work root '$($serverInfo.WorkRoot)'."
}

if ($Source.Count -gt 0) {
    $sources = @($Source | ForEach-Object { ([string]$_).Trim().TrimEnd('/') } | Where-Object { $_ })
} elseif ($binding -and $binding.Sources.Count -gt 0) {
    $sources = @($binding.Sources)
} else {
    $sources = @("$($serverInfo.WorkRoot)/$resolvedProject")
}
foreach ($relativePath in $sources) {
    Assert-VaspSafeRelativePath -Value $relativePath -Label 'Backup source path'
}
if (@($sources | Sort-Object -Unique).Count -ne $sources.Count) {
    throw 'Backup source paths must be unique.'
}

$resolvedRoots = @($rootCandidates)
if (-not [string]::IsNullOrWhiteSpace($backupTarget.Root)) {
    $resolvedRoots = @($backupTarget.Root)
}
if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
    $resolvedRoots = @($BackupRoot)
}
foreach ($candidate in $resolvedRoots) {
    if ($candidate -notmatch '^/[A-Za-z0-9._/-]+$' -or $candidate.Contains('..')) {
        throw "Unsafe backup root: $candidate"
    }
}

$crossHost = ($serverInfo.ServerKey -ne $backupTarget.HostKey)
$targetSshAlias = if ($crossHost) { $backupTarget.SshAlias } else { $serverInfo.SshAlias }

$resolvedLabel = ''
if (-not [string]::IsNullOrWhiteSpace($Label)) {
    Assert-VaspSafeName -Value $Label -Pattern $nameRegex -Label 'Backup label'
    $resolvedLabel = $Label
}

$resolvedLocalDirectory = ''
if (-not [string]::IsNullOrWhiteSpace($LocalDirectory)) {
    $resolvedLocalDirectory = (Resolve-Path -LiteralPath $LocalDirectory -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedLocalDirectory -PathType Container)) {
        throw "Local directory is not a directory: $resolvedLocalDirectory"
    }
}

$excludeNames = @()
if ($ExcludeLargeFiles) {
    $excludeNames = @($largeFileNames)
}
$checksumEnabled = -not $SkipChecksum
$quotedSources = ConvertTo-BashLiteralList -Values $sources
$quotedRoots = ConvertTo-BashLiteralList -Values $resolvedRoots
$quotedExcludes = ConvertTo-BashLiteralList -Values $excludeNames
$checksumFlag = if ($checksumEnabled) { 'yes' } else { 'no' }

$plan = [pscustomobject]@{
    Server            = $serverInfo.ServerKey
    BackupHost        = $backupTarget.HostKey
    CrossHost         = $crossHost
    BackupSshAlias    = $backupTarget.SshAlias
    SshAlias          = $serverInfo.SshAlias
    Project           = $resolvedProject
    Sources           = ($sources -join ', ')
    BackupRoot        = ($resolvedRoots -join ', ')
    ProjectDirectory  = (($resolvedRoots | ForEach-Object { "$_/$resolvedProject" }) -join ' or ')
    BackupLayout      = '<项目目录>/<yyyyMMdd_HHmmss>/ (one folder per project; each backup is a subfolder)'
    Label             = $resolvedLabel
    LocalDirectory    = $resolvedLocalDirectory
    ExcludeLargeFiles = [bool]$ExcludeLargeFiles
    Checksum          = $checksumEnabled
    BindingPath       = $resolvedBindingPath
}

Write-Output 'Backup plan:'
$plan | Format-List | Out-String | Write-Output

if ($DryRun) {
    Write-Output 'Dry run: no remote connection was made and nothing was copied.'
    if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
        [void](Export-VaspResultJson -Path $ResultJsonPath -Object ([pscustomobject]@{ Status = 'DRY_RUN'; Plan = $plan }))
    }
    return $plan
}

& (Join-Path $PSScriptRoot 'check_ssh_hosts.ps1') -Server $serverInfo.ServerKey -ServerConfigPath $ServerConfigPath | Out-Host
if ($crossHost) {
    & (Join-Path $PSScriptRoot 'check_ssh_hosts.ps1') -Server $backupTarget.HostKey -ServerConfigPath $ServerConfigPath | Out-Host
}

$rootInspectScript = @'
set -u
for root in __ROOTS__; do
    if [[ -d "$root" ]]; then
        if [[ -w "$root" ]]; then echo "BACKUP_ROOT_OK|$root"; else echo "BACKUP_ROOT_NOT_WRITABLE|$root"; fi
    else
        echo "BACKUP_ROOT_MISSING|$root"
    fi
done
'@.Replace('__ROOTS__', $quotedRoots)

$sourceInspectScript = @'
set -u
for rel in __SOURCES__; do
    target="$HOME/$rel"
    if [[ ! -d "$target" ]]; then
        echo "SOURCE_MISSING|$rel"
        continue
    fi
    files="$(find "$target" -type f | wc -l | tr -d ' ')"
    bytes="$(find "$target" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
    echo "SOURCE|$rel|$files|$bytes"
done
'@.Replace('__SOURCES__', $quotedSources)

$rootInspection = Invoke-VaspRemoteBash -SshAlias $targetSshAlias -Script $rootInspectScript -FailureMessage "Backup root inspection failed on $($backupTarget.HostKey)"
$sourceInspection = Invoke-VaspRemoteBash -SshAlias $serverInfo.SshAlias -Script $sourceInspectScript -FailureMessage "Source inspection failed on $($serverInfo.ServerKey)"
$inspection = @($rootInspection) + @($sourceInspection)
$inspection | Out-Host

if (@($inspection | Where-Object { $_ -match '^BACKUP_ROOT_OK\|' }).Count -eq 0) {
    $missingRoots = @($inspection | Where-Object { $_ -match '^BACKUP_ROOT_MISSING\|' } | ForEach-Object { $_ -replace '^BACKUP_ROOT_MISSING\|', '' })
    $unwritableRoots = @($inspection | Where-Object { $_ -match '^BACKUP_ROOT_NOT_WRITABLE\|' } | ForEach-Object { $_ -replace '^BACKUP_ROOT_NOT_WRITABLE\|', '' })
    $hint = ''
    if ($missingRoots.Count -gt 0) {
        $hint = " On server '$($backupTarget.HostKey)' the backup root does not exist. Ask an administrator to create it once (for example: sudo mkdir -p $($missingRoots[0]) && sudo chmod 777 $($missingRoots[0])), or pass -BackupRoot with an existing writable path."
    } elseif ($unwritableRoots.Count -gt 0) {
        $hint = " On server '$($backupTarget.HostKey)' the backup root exists but this account cannot write to it. Ask an administrator to grant write permission, or pass -BackupRoot with an existing writable path."
    }
    throw "Backup was not started: none of the backup roots exists and is writable (tried: $($resolvedRoots -join ', ')). Nothing was copied.$hint"
}
if (@($inspection | Where-Object { $_ -match '^SOURCE_MISSING\|' }).Count -gt 0) {
    throw 'Backup was not started: a source directory is missing. Nothing was copied.'
}

if (-not $Yes) {
    Write-Output 'Plan only: nothing was copied. Re-run with -Yes to perform the backup.'
    if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
        [void](Export-VaspResultJson -Path $ResultJsonPath -Object ([pscustomobject]@{ Status = 'PLAN_ONLY'; Plan = $plan; Inspection = $inspection }))
    }
    return $plan
}

if ($crossHost) {
    if ($ExcludeLargeFiles) {
        throw 'Cross-host backups do not support -ExcludeLargeFiles yet. Run the backup without it.'
    }
    if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
        throw 'OpenSSH scp.exe was not found; it is required for cross-host backups.'
    }

    $sourceHome = (@(Invoke-VaspRemoteBash -SshAlias $serverInfo.SshAlias -Script 'printf %s "$HOME"' -FailureMessage 'Failed to resolve the source server HOME directory') -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($sourceHome)) {
        throw 'Could not resolve the source server HOME directory.'
    }
    $writableRoots = @($inspection | Where-Object { $_ -match '^BACKUP_ROOT_OK\|' } | ForEach-Object { $_ -replace '^BACKUP_ROOT_OK\|', '' })
    $destRoot = [string]$writableRoots[0]

    $timestamp = (@(Invoke-VaspRemoteBash -SshAlias $serverInfo.SshAlias -Script "date +'$timestampFormat'" -FailureMessage 'Failed to read the source server time') -join '').Trim()
    if ($timestamp -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Unsafe backup timestamp: $timestamp"
    }
    $projectRoot = "$destRoot/$resolvedProject"
    $runName = if ($resolvedLabel) { "${timestamp}_$($resolvedLabel)" } else { $timestamp }
    $dest = "$projectRoot/$runName"
    if ($dest -notmatch '^/[A-Za-z0-9._/-]+$' -or $dest.Contains('..')) {
        throw "Unsafe backup destination: $dest"
    }
    $sourceNames = @($sources | ForEach-Object { ($_ -split '/')[-1] })
    if (@($sourceNames | Sort-Object -Unique).Count -ne $sourceNames.Count) {
        throw 'Backup source directories must have unique names when copied into one backup folder.'
    }

    $prepareScript = @'
set -u
project_root='__PROJECT_ROOT__'
dest='__DEST__'
if [[ -e "$project_root" && ! -d "$project_root" ]]; then
    echo "ERROR: the project backup path exists but is not a directory: $project_root" >&2
    exit 4
fi
if [[ -d "$project_root" ]]; then
    if [[ ! -w "$project_root" ]]; then
        echo "ERROR: the project backup directory is not writable: $project_root" >&2
        exit 4
    fi
else
    if ! mkdir "$project_root"; then
        echo "ERROR: cannot create the project backup directory: $project_root" >&2
        exit 4
    fi
fi
if [[ -e "$dest" ]]; then
    echo "ERROR: backup destination already exists: $dest" >&2
    exit 4
fi
if ! mkdir "$dest"; then
    echo "ERROR: cannot create the backup destination: $dest" >&2
    exit 4
fi
echo "PROJECT_ROOT_SELECTED|$project_root"
echo "DEST_SELECTED|$dest"
'@.Replace('__PROJECT_ROOT__', $projectRoot).Replace('__DEST__', $dest)
    $prepareOutput = Invoke-VaspRemoteBash -SshAlias $targetSshAlias -Script $prepareScript -FailureMessage "Failed to create the backup destination on $($backupTarget.HostKey)"
    $prepareOutput | Out-Host

    foreach ($relativeSource in $sources) {
        & scp -3 -r -p -q "$($serverInfo.SshAlias):$relativeSource" "$($targetSshAlias):$dest/"
        if ($LASTEXITCODE -ne 0) {
            throw "Copying '$relativeSource' from $($serverInfo.ServerKey) to $($backupTarget.HostKey) failed. The incomplete backup was kept at $dest and nothing was removed."
        }
        Write-Output "COPIED|$($serverInfo.ServerKey):$relativeSource|$($backupTarget.HostKey):$dest/"
    }

    $sourceVerifyScript = @'
set -u
max_sha_bytes=__MAX_SHA_BYTES__
checksum_enabled='__CHECKSUM_ENABLED__'
for rel in __SOURCES__; do
    src="$HOME/$rel"
    name="$(basename "$rel")"
    if [[ ! -d "$src" ]]; then
        echo "VERIFY_SOURCE_MISSING|$name"
        continue
    fi
    sizes="$(cd "$src" && find . -type f -printf '%P|%s\n' | LC_ALL=C sort)"
    files="$(printf '%s\n' "$sizes" | grep -c . || true)"
    bytes="$(printf '%s\n' "$sizes" | awk -F'|' '{s+=$2} END {print s+0}')"
    size_digest="$(printf '%s' "$sizes" | sha256sum | cut -d' ' -f1)"
    hash_digest='skipped'
    checksummed=0
    if [[ "$checksum_enabled" == 'yes' ]]; then
        hashes="$(cd "$src" && find . -type f -size -${max_sha_bytes}c -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)"
        checksummed="$(printf '%s\n' "$hashes" | grep -c . || true)"
        hash_digest="$(printf '%s' "$hashes" | sha256sum | cut -d' ' -f1)"
    fi
    echo "VERIFY_SOURCE|$name|$files|$bytes|$checksummed|$size_digest|$hash_digest"
done
'@.Replace('__MAX_SHA_BYTES__', [string]$maxShaBytes).Replace('__CHECKSUM_ENABLED__', $checksumFlag).Replace('__SOURCES__', $quotedSources)

    $targetVerifyScript = @'
set -u
dest='__DEST__'
max_sha_bytes=__MAX_SHA_BYTES__
checksum_enabled='__CHECKSUM_ENABLED__'
manifest_name='__MANIFEST_NAME__'
checksum_name='__CHECKSUM_NAME__'
for name in __NAMES__; do
    tgt="$dest/$name"
    if [[ ! -d "$tgt" ]]; then
        echo "VERIFY_TARGET_MISSING|$name"
        continue
    fi
    sizes="$(cd "$tgt" && find . -type f -printf '%P|%s\n' | LC_ALL=C sort)"
    files="$(printf '%s\n' "$sizes" | grep -c . || true)"
    bytes="$(printf '%s\n' "$sizes" | awk -F'|' '{s+=$2} END {print s+0}')"
    size_digest="$(printf '%s' "$sizes" | sha256sum | cut -d' ' -f1)"
    hash_digest='skipped'
    checksummed=0
    if [[ "$checksum_enabled" == 'yes' ]]; then
        hashes="$(cd "$tgt" && find . -type f -size -${max_sha_bytes}c -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)"
        checksummed="$(printf '%s\n' "$hashes" | grep -c . || true)"
        hash_digest="$(printf '%s' "$hashes" | sha256sum | cut -d' ' -f1)"
    fi
    echo "VERIFY_TARGET|$name|$files|$bytes|$checksummed|$size_digest|$hash_digest"
done
{
    echo "project=__PROJECT__"
    echo "timestamp=__TIMESTAMP__"
    echo "project_root=__PROJECT_ROOT__"
    echo "server_backup_dir=$dest"
    echo "source_server=__SOURCE_SERVER__"
    echo "sources=__SOURCES_TEXT__"
    echo "copy_mode=cross-host scp -3 via the workstation"
    echo "checksum_enabled=$checksum_enabled"
    echo "sha256_max_size_bytes=$max_sha_bytes"
    echo "created_by=skill vasp-task-backup backup_current_task.ps1"
    echo "--- file listing (relative path|size) ---"
    for name in __NAMES__; do
        echo "[$name]"
        (cd "$dest/$name" && find . -type f -printf '%P|%s\n' | LC_ALL=C sort)
    done
} > "$dest/$manifest_name"
if [[ "$checksum_enabled" == 'yes' ]]; then
    {
        echo "# sha256 manifest, computed from the backup copy"
        for name in __NAMES__; do
            echo "[$name]"
            (cd "$dest/$name" && find . -type f -size -${max_sha_bytes}c -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
        done
    } > "$dest/$checksum_name"
fi
'@.Replace('__DEST__', $dest).Replace('__MAX_SHA_BYTES__', [string]$maxShaBytes).Replace('__CHECKSUM_ENABLED__', $checksumFlag).Replace('__MANIFEST_NAME__', $manifestName).Replace('__CHECKSUM_NAME__', $checksumName).Replace('__NAMES__', (ConvertTo-BashLiteralList -Values $sourceNames)).Replace('__PROJECT__', $resolvedProject).Replace('__TIMESTAMP__', $timestamp).Replace('__PROJECT_ROOT__', $projectRoot).Replace('__SOURCE_SERVER__', $serverInfo.ServerKey).Replace('__SOURCES_TEXT__', ($sources -join ','))

    $sourceVerify = Invoke-VaspRemoteBash -SshAlias $serverInfo.SshAlias -Script $sourceVerifyScript -FailureMessage "Source verification failed on $($serverInfo.ServerKey)"
    $targetVerify = Invoke-VaspRemoteBash -SshAlias $targetSshAlias -Script $targetVerifyScript -FailureMessage "Backup verification failed on $($backupTarget.HostKey)"
    $sourceVerify | Out-Host
    $targetVerify | Out-Host

    $sourceVerifyMap = @{}
    foreach ($line in $sourceVerify) {
        if ($line -match '^VERIFY_SOURCE\|(?<name>[^|]+)\|(?<files>\d+)\|(?<bytes>\d+)\|(?<checksummed>\d+)\|(?<size>[0-9a-f]+)\|(?<hash>[0-9a-fa-z]+)$') {
            $sourceVerifyMap[$matches.name] = $matches
        }
    }
    $targetVerifyMap = @{}
    foreach ($line in $targetVerify) {
        if ($line -match '^VERIFY_TARGET\|(?<name>[^|]+)\|(?<files>\d+)\|(?<bytes>\d+)\|(?<checksummed>\d+)\|(?<size>[0-9a-f]+)\|(?<hash>[0-9a-fa-z]+)$') {
            $targetVerifyMap[$matches.name] = $matches
        }
    }

    $totalFiles = [int64]0
    $totalBytes = [int64]0
    $totalChecksummed = [int64]0
    foreach ($name in $sourceNames) {
        if (-not $sourceVerifyMap.ContainsKey($name)) {
            throw "Source verification did not report '$name'."
        }
        if (-not $targetVerifyMap.ContainsKey($name)) {
            throw "The backup copy of '$name' is missing or incomplete at $dest. Nothing was removed."
        }
        $sourceStats = $sourceVerifyMap[$name]
        $targetStats = $targetVerifyMap[$name]
        $mismatch = (
            $sourceStats.files -ne $targetStats.files -or
            $sourceStats.bytes -ne $targetStats.bytes -or
            $sourceStats.size -ne $targetStats.size -or
            ($checksumEnabled -and $sourceStats.hash -ne $targetStats.hash)
        )
        if ($mismatch) {
            throw "Verification failed for '$name': the copy at $dest does not match the source on $($serverInfo.ServerKey). The incomplete backup was kept and nothing was removed."
        }
        $totalFiles += [int64]$sourceStats.files
        $totalBytes += [int64]$sourceStats.bytes
        $totalChecksummed += [int64]$sourceStats.checksummed
    }

    $fields = @{
        project      = $resolvedProject
        timestamp    = $timestamp
        project_root = $projectRoot
        dest         = $dest
        sources      = [string]$sources.Count
        files        = [string]$totalFiles
        bytes        = [string]$totalBytes
        checksummed  = [string]$totalChecksummed
        verify       = 'PASS'
    }
    $backupDirectory = $dest
    Write-Output "RESULT|project=$resolvedProject|timestamp=$timestamp|project_root=$projectRoot|dest=$dest|sources=$($sources.Count)|files=$totalFiles|bytes=$totalBytes|checksummed=$totalChecksummed|verify=PASS"
} else {
$backupScript = @'
set -euo pipefail

project='__PROJECT__'
label='__LABEL__'
max_sha_bytes=__MAX_SHA_BYTES__
checksum_enabled='__CHECKSUM_ENABLED__'
manifest_name='__MANIFEST_NAME__'
checksum_name='__CHECKSUM_NAME__'
sources=(__SOURCES__)
exclude_names=(__EXCLUDES__)

backup_root=''
for candidate in __ROOTS__; do
    if [[ -d "$candidate" && -w "$candidate" ]]; then
        backup_root="$candidate"
        break
    fi
done
if [[ -z "$backup_root" ]]; then
    echo "ERROR: no writable backup root among: __ROOTS__" >&2
    exit 4
fi
echo "BACKUP_ROOT_SELECTED|$backup_root"

src_paths=()
dst_names=()
for rel in "${sources[@]}"; do
    if [[ ! "$rel" =~ ^[A-Za-z0-9._/-]+$ || "$rel" == /* || "$rel" == *..* ]]; then
        echo "ERROR: unsafe source path: $rel" >&2
        exit 4
    fi
    src="$HOME/$rel"
    if [[ ! -d "$src" ]]; then
        echo "ERROR: source directory does not exist: $src" >&2
        exit 4
    fi
    real="$(realpath -e "$src")"
    case "$real" in
        "$HOME"/*) ;;
        *) echo "ERROR: source resolves outside HOME: $src" >&2; exit 4 ;;
    esac
    name="$(basename "$real")"
    for existing in ${dst_names[@]+"${dst_names[@]}"}; do
        if [[ "$existing" == "$name" ]]; then
            echo "ERROR: duplicate source directory name: $name" >&2
            exit 4
        fi
    done
    src_paths+=("$real")
    dst_names+=("$name")
done

timestamp="$(date +'__TIMESTAMP_FORMAT__')"
project_root="$backup_root/$project"
if [[ -e "$project_root" && ! -d "$project_root" ]]; then
    echo "ERROR: the project backup path exists but is not a directory: $project_root" >&2
    exit 4
fi
if [[ -d "$project_root" ]]; then
    if [[ ! -w "$project_root" ]]; then
        echo "ERROR: the project backup directory is not writable: $project_root" >&2
        exit 4
    fi
else
    if ! mkdir "$project_root"; then
        echo "ERROR: cannot create the project backup directory: $project_root" >&2
        exit 4
    fi
fi
echo "PROJECT_ROOT_SELECTED|$project_root"
if [[ -n "$label" ]]; then
    dest="$project_root/${timestamp}_${label}"
else
    dest="$project_root/${timestamp}"
fi
if [[ -e "$dest" ]]; then
    echo "ERROR: backup destination already exists: $dest" >&2
    exit 4
fi

excluded_text='none'
if (( ${#exclude_names[@]} > 0 )); then
    excluded_text="${exclude_names[*]}"
fi

find_expr=()
for name in ${exclude_names[@]+"${exclude_names[@]}"}; do
    find_expr+=(! -name "$name")
done

list_files() {
    ( cd "$1" && find . -type f ${find_expr[@]+"${find_expr[@]}"} -print0 | sort -z | xargs -0 -r stat -c '%n|%s' )
}

list_sha() {
    ( cd "$1" && find . -type f ${find_expr[@]+"${find_expr[@]}"} -size -${max_sha_bytes}c -print0 | sort -z | xargs -0 -r sha256sum )
}

mkdir "$dest"
for index in "${!src_paths[@]}"; do
    src="${src_paths[$index]}"
    name="${dst_names[$index]}"
    target="$dest/$name"
    if (( ${#exclude_names[@]} > 0 )); then
        mkdir "$target"
        tar_excludes=()
        for excluded in "${exclude_names[@]}"; do
            tar_excludes+=(--exclude="$excluded" --exclude="*/$excluded" --exclude="./$excluded")
        done
        tar -C "$src" "${tar_excludes[@]}" -cf - . | tar -C "$target" -xf -
    else
        cp -a "$src" "$target"
    fi
done

total_files=0
total_bytes=0
total_checksummed=0
for index in "${!src_paths[@]}"; do
    src="${src_paths[$index]}"
    name="${dst_names[$index]}"
    target="$dest/$name"
    if ! diff -q <(list_files "$src") <(list_files "$target") >/dev/null; then
        echo "ERROR: file list or file sizes differ between $src and $target" >&2
        echo "WARNING: the incomplete backup was kept at $dest and nothing was removed." >&2
        exit 6
    fi
    files="$(list_files "$src" | wc -l | tr -d ' ')"
    bytes="$(list_files "$src" | awk -F'|' '{sum+=$2} END {print sum+0}')"
    checksummed=0
    if [[ "$checksum_enabled" == 'yes' ]]; then
        if ! diff -q <(list_sha "$src") <(list_sha "$target") >/dev/null; then
            echo "ERROR: SHA256 manifest mismatch between $src and $target" >&2
            echo "WARNING: the incomplete backup was kept at $dest and nothing was removed." >&2
            exit 6
        fi
        checksummed="$(list_sha "$src" | wc -l | tr -d ' ')"
    fi
    total_files=$((total_files + files))
    total_bytes=$((total_bytes + bytes))
    total_checksummed=$((total_checksummed + checksummed))
    echo "SOURCE|name=$name|files=$files|bytes=$bytes|checksummed=$checksummed|source=$src"
done

{
    echo "project=$project"
    echo "timestamp=$timestamp"
    echo "project_root=$project_root"
    echo "server_backup_dir=$dest"
    echo "sources=${sources[*]}"
    echo "excluded=$excluded_text"
    echo "checksum_enabled=$checksum_enabled"
    echo "sha256_max_size_bytes=$max_sha_bytes"
    echo "created_by=skill vasp-task-backup backup_current_task.ps1"
    echo "--- file listing (relative path|size) ---"
    for index in "${!src_paths[@]}"; do
        echo "[${dst_names[$index]}]"
        list_files "${src_paths[$index]}"
    done
} > "$dest/$manifest_name"

if [[ "$checksum_enabled" == 'yes' ]]; then
    {
        echo "# sha256 manifest, computed from the source directories"
        for index in "${!src_paths[@]}"; do
            echo "[${dst_names[$index]}]"
            list_sha "${src_paths[$index]}"
        done
    } > "$dest/$checksum_name"
fi

echo "RESULT|project=$project|timestamp=$timestamp|project_root=$project_root|dest=$dest|sources=${#src_paths[@]}|files=$total_files|bytes=$total_bytes|checksummed=$total_checksummed|verify=PASS"
'@.Replace('__PROJECT__', $resolvedProject).Replace('__LABEL__', $resolvedLabel).Replace('__MAX_SHA_BYTES__', [string]$maxShaBytes).Replace('__CHECKSUM_ENABLED__', $checksumFlag).Replace('__MANIFEST_NAME__', $manifestName).Replace('__CHECKSUM_NAME__', $checksumName).Replace('__SOURCES__', $quotedSources).Replace('__EXCLUDES__', $quotedExcludes).Replace('__ROOTS__', $quotedRoots).Replace('__TIMESTAMP_FORMAT__', $timestampFormat)

$backupOutput = Invoke-VaspRemoteBash -SshAlias $serverInfo.SshAlias -Script $backupScript -FailureMessage 'Remote backup failed'
$backupOutput | Out-Host

$resultLine = @($backupOutput | Where-Object { $_ -match '^RESULT\|' }) | Select-Object -Last 1
if (-not $resultLine) {
    throw "Backup finished without a result line; inspect the output above.`n$($backupOutput -join [Environment]::NewLine)"
}
$fields = @{}
$parts = $resultLine.Split('|')
foreach ($part in $parts[1..($parts.Length - 1)]) {
    $pair = $part.Split('=', 2)
    if ($pair.Length -eq 2) {
        $fields[$pair[0]] = $pair[1]
    }
}
$backupDirectory = [string]$fields['dest']
}

$localFileCount = 0
$localBytes = 0
$localVerify = 'NOT_REQUESTED'
if ($resolvedLocalDirectory) {
    $remoteLocalDirectory = "$backupDirectory/$localSubdirectory"
    & ssh -o BatchMode=yes $targetSshAlias "mkdir -p '$remoteLocalDirectory'"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the remote local-project directory: $remoteLocalDirectory"
    }
    $leaf = Split-Path -Leaf $resolvedLocalDirectory
    $localFiles = @(Get-ChildItem -LiteralPath $resolvedLocalDirectory -Recurse -File -Force)
    $localRows = foreach ($file in $localFiles) {
        $relative = $file.FullName.Substring($resolvedLocalDirectory.Length).TrimStart([char[]]@('\', '/')) -replace '\\', '/'
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  ./$relative"
    }
    $localManifest = (@($localRows) | Sort-Object) -join "`n"
    $localFileCount = $localFiles.Count
    $localBytes = ($localFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $localBytes) { $localBytes = 0 }

    & scp -q -r $resolvedLocalDirectory "$($targetSshAlias):$remoteLocalDirectory/"
    if ($LASTEXITCODE -ne 0) {
        throw "Uploading the local project directory failed. The server-side backup was kept at $backupDirectory."
    }

    $verifyScript = @'
set -euo pipefail
target="__TARGET__"
if [[ ! -d "$target" ]]; then
    echo "ERROR: uploaded local project directory is missing: $target" >&2
    exit 5
fi
cd "$target"
find . -type f -print0 | sort -z | xargs -0 -r sha256sum
'@.Replace('__TARGET__', "$remoteLocalDirectory/$leaf")
    $remoteRows = Invoke-VaspRemoteBash -SshAlias $targetSshAlias -Script $verifyScript -FailureMessage 'Local project verification failed'
    $remoteManifest = (@($remoteRows | Where-Object { $_ -match '^[0-9a-f]{64}  ' }) | Sort-Object) -join "`n"
    if ($localManifest -eq $remoteManifest) {
        $localVerify = 'SHA256_PASS'
    } else {
        $localVerify = 'SHA256_FAILED'
    }
    Write-Output "LOCAL_PROJECT|files=$localFileCount|bytes=$localBytes|verify=$localVerify|remote=$remoteLocalDirectory/$leaf"
}

$serverMb = [math]::Round(([int64]$fields['bytes']) / 1MB, 2)
$verificationText = "服务器 $($fields['files']) 文件 / $serverMb MB / SHA256 $(if ($checksumEnabled) { 'PASS' } else { 'SKIPPED' })"
if ($resolvedLocalDirectory) {
    $localMb = [math]::Round($localBytes / 1MB, 2)
    $verificationText = "$verificationText；本机项目 $localFileCount 文件 / $localMb MB / $localVerify"
}

$result = [pscustomobject]@{
    Status           = 'BACKED_UP'
    Server           = $serverInfo.ServerKey
    SshAlias         = $serverInfo.SshAlias
    Project          = [string]$fields['project']
    Timestamp        = [string]$fields['timestamp']
    ProjectDirectory = [string]$fields['project_root']
    BackupDirectory  = $backupDirectory
    SourcePaths      = ($sources -join ', ')
    SourceCount      = [int]$fields['sources']
    FileCount        = [int64]$fields['files']
    SizeMB           = $serverMb
    ChecksummedFiles = [int64]$fields['checksummed']
    Verify           = [string]$fields['verify']
    LocalDirectory   = $resolvedLocalDirectory
    LocalFileCount   = $localFileCount
    LocalSizeMB      = [math]::Round($localBytes / 1MB, 2)
    LocalVerify      = $localVerify
    VerificationText = $verificationText
    BindingPath      = $resolvedBindingPath
}

if (-not [string]::IsNullOrWhiteSpace($ResultJsonPath)) {
    [void](Export-VaspResultJson -Path $ResultJsonPath -Object $result)
}

$result
