# vasp-task-backup

Codex skill：把一个 VASP 项目的服务器端计算目录归档到备份主机的 `/home/bak`，并把任务关键信息登记到该主机上的 `VaspTaskList.md`。

项目在 **yang** 时，复制在 yang 本机完成；项目在 **lan** 时，数据经本机 OpenSSH 用 `scp -3` 中转复制到 yang，在源、目标两侧各自计算清单摘要并比对，一致才算通过。所有项目的备份和日志都落在**同一台备份主机**（默认 yang）上，所以 lan 自己不需要 `/home/bak`，也不需要管理员在 lan 上额外授权。

本 skill 独立运行，不依赖 `fang-ssh-skill`；它只做备份与登记，不提交、不监控、不取消 VASP 作业。

## 特性

- **一个项目一个文件夹**：`/home/bak/<项目名>/`，每次备份进入 `<yyyyMMdd_HHmmss>` 子目录；同名目录已存在时停止，不覆盖、不合并、不删除。
- **先计划后执行**：不带 `-Yes` 只做只读检查（备份根可写性、每个源目录的文件数和总大小）并打印目标路径，确认后才复制。
- **复制后校验**：逐项比对文件数、总字节数和 SHA256 清单，输出 `verify=PASS` 才算成功；失败时保留不完整目录并报告位置，不自动清理。
- **统一任务日志**：`/home/bak/VaspTaskList.md` 全局一份，`服务器` 列区分 yang/lan；`flock` 加锁 + 临时文件原子替换，同一任务ID再次写入时更新原行。
- **可选归档本机目录**：`-LocalDirectory` 把本机项目目录上传到备份目录的 `local_project/`，同样做 SHA256 核对。

## 前置条件

| 项 | 要求 |
|---|---|
| 本机 | Windows + PowerShell 5.1 或 PowerShell 7 |
| OpenSSH | `ssh`、`scp` 在 PATH 中（Windows 自带的 OpenSSH 客户端即可） |
| 免密登录 | 本机 SSH config 中已有 `yang-login`、`lan-login`，且已配置公钥登录（`ssh yang-login id -un` 不提示密码） |
| 备份主机 | 备份主机（默认 yang）上的 `/home/bak` 已存在且当前账号可写 |
| 项目主机 | 任务目录位于项目所在服务器的 `~/vasp_codex/` 下 |

缺少 `/home/bak` 或不可写时脚本会拒绝执行并打印管理员命令，不会提权，也不会静默改写到别的目录。临时替代是显式传 `-BackupRoot`、`-LogPath` 指向已存在且可写的目录。

## 安装

### 方式一：git clone（推荐）

```powershell
$dest = Join-Path $HOME '.codex\skills\vasp_task_backup'
git clone https://github.com/qzfjw/vasp_task_backup.git $dest
```

如果该目录已存在（例如之前手动拷过一份），先改名或删掉再 clone。

更新到最新版本：

```powershell
git -C $dest pull --ff-only
```

### 方式二：手动复制

把仓库整个目录放到下面这个位置：

```text
%USERPROFILE%\.codex\skills\vasp_task_backup
```

要点是保留 `SKILL.md` 与 `scripts/`、`config/`、`references/` 的相对位置，不要只复制脚本。

### 目录结构

```text
vasp_task_backup/
├─ SKILL.md                             skill 定义（Codex 读取）
├─ README.md                            本文件
├─ agents/openai.yaml                   界面名称与默认提示词
├─ config/
│  ├─ servers.psd1                      预置服务器与备份主机
│  ├─ servers.local.example.psd1        本机覆盖示例
│  └─ rules/backup-rules.psd1           项目名、备份布局、日志列定义
├─ references/task-log-format.md        日志字段与写入规则
└─ scripts/
   ├─ lib/VaspTaskBackup.psm1           公共函数
   ├─ new_vasp_project.ps1              建立当前任务的项目绑定
   ├─ backup_current_task.ps1           备份当前项目
   ├─ update_task_log.ps1               写入或更新任务日志
   ├─ backup_and_log.ps1                备份 + 登记（推荐入口）
   ├─ list_vasp_projects.ps1            查看远程目录、备份与日志
   ├─ select_server.ps1                 加载指定服务器的配置与环境
   └─ check_ssh_hosts.ps1               检查 SSH 别名解析与免密登录
```

### 首次配置

`config/servers.psd1` 已预置 yang、lan 的 SSH 别名和备份主机。只有需要在本机覆盖别名、主机或备份主机时才创建本地配置：

```powershell
$SkillRoot = Join-Path $HOME '.codex\skills\vasp_task_backup'
Copy-Item "$SkillRoot/config/servers.local.example.psd1" "$SkillRoot/config/servers.local.psd1"
```

`config/servers.local.psd1` 是本机私有配置，已被 `.gitignore` 排除，不要提交。

### 验证安装

```powershell
$SkillRoot = Join-Path $HOME '.codex\skills\vasp_task_backup'

# 检查两台服务器的免密登录
& "$SkillRoot/scripts/check_ssh_hosts.ps1" -Server yang
& "$SkillRoot/scripts/check_ssh_hosts.ps1" -Server lan

# 列出远程任务目录、已有备份和日志文件（只读）
& "$SkillRoot/scripts/list_vasp_projects.ps1" -Server yang
```

`Status : PASS` 表示该服务器可用。之后在对话中用 `$vasp-task-backup` 触发这个 skill。

## 使用

一个任务对应一个项目，备份默认只针对“当前项目”。当前项目由当前目录（或其上层目录）中的 `.codex-vasp-project.json` 唯一确定。

### 1. 开始新任务时建立项目

```powershell
$SkillRoot = Join-Path $HOME '.codex\skills\vasp_task_backup'

& "$SkillRoot/scripts/new_vasp_project.ps1" `
  -Server yang `
  -ProjectName mos2_u `
  -Source vasp_codex/mos2_u_relax,vasp_codex/mos2_u_scf,vasp_codex/mos2_u_band
```

脚本在当前目录写入 `.codex-vasp-project.json`，记录服务器、项目名、工作根目录和本项目包含的远程目录；不加 `-Source` 时默认只包含 `vasp_codex/<项目名>`。项目名必须匹配 `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`。加 `-CreateRemote` 会顺便创建缺失的远程目录，`-Force` 才会覆盖已存在的绑定。

### 2. 先看计划

```powershell
& "$SkillRoot/scripts/backup_current_task.ps1"
```

这一步连接服务器做只读检查：备份根是否存在且可写、每个源目录的文件数与总大小，并打印将要写入的目标路径。不复制任何文件，也不写日志。

### 3. 备份并登记日志（推荐）

```powershell
& "$SkillRoot/scripts/backup_and_log.ps1" -Yes `
  -Purpose '用于 2H-MoS2 能带图' `
  -Conclusion 'PBE 带隙约 1.6 eV，间接带隙'
```

- 不带 `-Yes` 时同样只打印计划，不复制、不写日志；只想看计划也可以显式加 `-DryRun`。
- 备份成功后自动写入 `VaspTaskList.md`，并报告任务ID、备份目录、文件数/大小和 `verify` 结果。
- 校验结果不是 `PASS` 时不会写日志，也不会声称成功。

### 4. 连同本机项目目录一起归档

```powershell
& "$SkillRoot/scripts/backup_and_log.ps1" -Yes -LocalDirectory '.\mos2_u' `
  -Purpose '用于能带图' -Conclusion '带隙 1.6 eV'
```

本机目录会上传到本次备份目录的 `local_project/` 下，并做 SHA256 核对（结果里显示 `LocalVerify : SHA256_PASS`）。

### 5. 只更新日志

```powershell
& "$SkillRoot/scripts/update_task_log.ps1" -Yes `
  -TaskId VT-20260913-162837-mos2_u `
  -Purpose '用于能带图' -Conclusion '带隙 1.6 eV'
```

这条路径不复制数据，只写日志。注意它会用本次传入的字段重建整行，没传的字段（例如 `-BackupDirectory`、`-Verification`）会留空，所以补写结论时要把已有的备份地址一并带上。

### 6. 查看现状

```powershell
& "$SkillRoot/scripts/list_vasp_projects.ps1" -Server yang
& "$SkillRoot/scripts/list_vasp_projects.ps1" -Server lan
```

列出 `~/vasp_codex` 下的任务目录（文件数、大小、是否为当前绑定）、备份根下已有的项目文件夹与备份子目录，以及日志文件大小。

### 忘记先声明项目怎么办

不要凭目录名猜归属。先列出远程目录，让用户确认哪些属于当前任务，再补绑定后备份：

```powershell
& "$SkillRoot/scripts/list_vasp_projects.ps1" -Server yang

& "$SkillRoot/scripts/new_vasp_project.ps1" -Server yang -ProjectName mos2_u `
  -Source vasp_codex/mos2_u_relax,vasp_codex/mos2_u_scf

& "$SkillRoot/scripts/backup_and_log.ps1" -Yes -Purpose '...' -Conclusion '...'
```

## 备份目录结构

```text
/home/bak/
├─ VaspTaskList.md                     统一任务日志（所有服务器共用一份）
└─ <项目名>/                           一个项目只占这一个文件夹
   ├─ <yyyyMMdd_HHmmss>/               每次备份一个时间戳子目录
   │  ├─ <远程任务目录名>/             原样复制，含全部文件
   │  ├─ local_project/                可选：本机项目目录
   │  ├─ codex-backup-manifest.txt     文件清单、来源与时间
   │  └─ codex-backup-sha256.txt       SHA256 清单（默认对不超过 256 MB 的文件计算）
   └─ ...                              项目文件夹里可以再放自己的图表、说明等
```

同一个项目重复备份只新增时间戳子目录，项目文件夹已存在时直接复用。目标子目录同名时停止，不覆盖、不合并、不删除。需要给本次备份一个可读后缀时加 `-Label v2`，目录写成 `<时间戳>_v2`。

## 任务日志

日志写在**备份主机**的 `/home/bak/VaspTaskList.md`（全局一份，yang 和 lan 的项目都登记在这里，靠 `服务器` 列区分）。文件不存在时自动创建；已存在时只在表格中追加或更新对应任务ID的行，不重写原有内容。字段定义与写入规则见 `references/task-log-format.md`。

| 列 | 含义 |
|---|---|
| 任务ID | 默认 `VT-<yyyyMMdd>-<HHmmss>-<项目名>`，也可用 `-TaskId` 指定 |
| 时间 | 写入时的服务器本地时间 |
| 服务器 | 项目所在的服务器（yang / lan） |
| 任务地址 | 项目服务器上展开后的真实远程目录 |
| 备份地址 | 本次备份目录 |
| 使用者 | 项目所在服务器上提交任务的账号（`id -un`） |
| 使用过程 | 这批计算用于做什么图、表或流程 |
| 计算结论 | 计算结果的核心结论 |
| 备份校验 | 文件数、大小、SHA256 结果 |
| 备注 | 可选 |

## 配置：备份主机与跨服务器

备份主机由 `config/servers.psd1` 的 `Common.Backup` 决定：

```powershell
Common = @{
    WorkRoot = 'vasp_codex'
    Backup   = @{
        Host    = 'yang'                     # 所有备份和日志都落在这台服务器
        Root    = '/home/bak'
        LogPath = '/home/bak/VaspTaskList.md'
    }
}
```

把 `Host` 改成 `lan` 即可把落点整体换到 lan，其余逻辑不变。

- **项目在 yang**：在 yang 本机用 `cp -a` 复制到 `/home/bak/<项目名>/<时间戳>/`，逐文件比对文件数、字节数和 SHA256。
- **项目在 lan**：用本机 `scp -3 -r -p` 把 `lan:~/vasp_codex/<目录>` 经本机中转复制到 `yang:/home/bak/...`，然后在 lan 和 yang 两侧分别计算清单摘要（文件数、字节数、路径尺寸表摘要、SHA256 摘要）并比对，两侧完全一致才算 `verify=PASS`。数据不在本机落盘，也不要求 lan 能登录 yang。

## 权限与限制

- `/home/bak` 必须已在备份主机上存在且当前账号可写。缺失或不可写时脚本输出 `BACKUP_ROOT_MISSING` / `BACKUP_ROOT_NOT_WRITABLE` 并停止，不复制任何文件。
- 本 skill 不提权（不使用 `sudo`），也不静默改写到其他路径；需要换落点时显式传 `-BackupRoot`、`-LogPath`。
- `-ExcludeLargeFiles`（跳过 `WAVECAR`、`CHGCAR`）目前只在项目与备份主机为同一台机器时可用；跨服务器备份会直接报错，而不是悄悄退化成完整复制。
- 需要跳过校验时用 `-SkipChecksum`，此时日志的 `备份校验` 列内容会相应变化。

## 安全边界

- 服务器必须由用户明确指定，不设置默认服务器。
- 只备份当前项目绑定文件列出的远程目录，不扫描、不猜测、不连带 `~/vasp_codex` 下的其他任务。
- 不使用 `sudo`、不修改 SSH 配置、不删除远程目录。
- 校验结果不是 `PASS` 时不写日志、不声称成功。
- 不保存或回显服务器密码、私钥内容和 Materials Project API Key。

## 脚本一览

| 脚本 | 作用 |
|---|---|
| `scripts/new_vasp_project.ps1` | 建立 `.codex-vasp-project.json`，可选创建缺失的远程目录 |
| `scripts/backup_current_task.ps1` | 备份当前项目；不加 `-Yes` 只打印计划 |
| `scripts/backup_and_log.ps1` | 备份成功后写入任务日志（推荐入口） |
| `scripts/update_task_log.ps1` | 只更新 `VaspTaskList.md`，不复制数据 |
| `scripts/list_vasp_projects.ps1` | 列出远程任务目录、已有备份和日志文件 |
| `scripts/select_server.ps1` | 加载指定服务器的配置与环境 |
| `scripts/check_ssh_hosts.ps1` | 检查 SSH 别名解析与免密登录 |

## 常见问题

**备份会不会把别的任务一起传上去？**
不会。只复制当前项目绑定文件里列出的目录；没有绑定就报错停止，也可以用 `-Source` 显式指定。

**重复备份会覆盖上一次吗？**
不会。每次都进新的时间戳子目录，已有目录一律不动。

**备份到一半失败了怎么办？**
脚本保留已复制的部分并报告位置，不自动清理，也不会写日志。

**能不能跳过 WAVECAR、CHGCAR？**
项目与备份主机同机时可以加 `-ExcludeLargeFiles`；跨服务器（lan → yang）目前会直接报错，请保持完整备份或先手动处理。

**日志能和别人共用一份吗？**
可以。`/home/bak/VaspTaskList.md` 是全局一份，写入用 `flock` 加锁并原子替换，多人同时写入不会互相覆盖。
