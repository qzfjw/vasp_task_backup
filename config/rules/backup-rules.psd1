@{
    SchemaVersion = 1

    Project = @{
        BindingFileName      = '.codex-vasp-project.json'
        BindingSchemaVersion = 1
        NameRegex            = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    }

    Backup = @{
        RootCandidates    = @('/home/bak')
        TimestampFormat   = '%Y%m%d_%H%M%S'
        LargeFileNames    = @('WAVECAR', 'CHGCAR')
        Sha256MaxSizeMB   = 256
        ManifestName      = 'codex-backup-manifest.txt'
        ChecksumFileName  = 'codex-backup-sha256.txt'
        LocalSubdirectory = 'local_project'
    }

    TaskLog = @{
        PathCandidates = @('/home/bak/VaspTaskList.md')
        Title          = '# VASP 任务备份日志'
        Intro          = '由 Codex skill vasp-task-backup 维护：每行一个任务，同一任务ID再次备份时更新该行。'
        TableTitle     = '## 备份记录'
        TaskIdPrefix   = 'VT'
        Columns        = @('任务ID', '时间', '服务器', '任务地址', '备份地址', '使用者', '使用过程', '计算结论', '备份校验', '备注')
    }
}
