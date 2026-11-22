@{
    SchemaVersion = 2

    Backup = @{
        RootPath          = '/home/bak'
        LogPath           = '/home/bak/VaspLog.xlsx'
        InternalDirectory = '.vasp_task_backup'
        IndexFileName     = 'index.json'
        RequiredFiles     = @('INCAR', 'POSCAR')
        CompletionMarker  = 'General timing and accounting informations for this job'
        KeepLogBackups    = 5
    }

    VaspLog = @{
        Worksheet = 'VaspLog'
        TableName = 'VaspLogTable'
        Columns   = @('编号', '关联任务编号', '操作人', '时间', '计算说明', '使用记录', '任务所在文件夹')
    }
}
