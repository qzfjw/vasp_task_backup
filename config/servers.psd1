@{
    Common = @{
        WorkRoot = 'vasp_codex'

        # 所有项目的备份和任务日志统一落到这一台服务器，不管项目在 yang 还是 lan。
        Backup = @{
            Host    = 'yang'
            Root    = '/home/bak'
            LogPath = '/home/bak/VaspTaskList.md'
        }
    }

    Servers = @{
        yang = @{
            DisplayName = 'Yang'
            SshAlias    = 'yang-login'
            HostName    = '172.17.19.200'
            Port        = 22
        }
        lan = @{
            DisplayName = 'Lan'
            SshAlias    = 'lan-login'
            HostName    = '192.168.22.201'
            Port        = 22
        }
    }
}
