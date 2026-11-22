@{
    Common = @{
        WorkRoot = 'vasp_codex'

        # 所有任务的镜像备份和 VaspLog.xlsx 统一落到这一台服务器。
        Backup = @{
            Host    = 'yang'
            Root    = '/home/bak'
            LogPath = '/home/bak/VaspLog.xlsx'
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
