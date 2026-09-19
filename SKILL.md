---
name: vasp-task-backup
description: 把当前 VASP 项目的服务器端计算目录备份到备份主机（默认 yang）的 /home/bak，lan 上的项目经本机中转复制过去，并更新该主机上的 VaspTaskList.md 任务日志（任务ID、任务地址、时间、使用者、使用过程、计算结论、备份校验）。当用户要求备份 VASP 算例、归档计算任务、登记任务日志或记录计算结论时使用；不负责提交、监控或取消 VASP 作业。
---

# VASP 任务备份与日志

## 用途

对当前项目的 VASP 计算任务做服务器端归档：把 `~/vasp_codex/<目录>` 复制到 `/home/bak/<项目名>/<服务器时间戳>/`，校验文件数、字节数和 SHA256，并把任务关键信息登记到服务器上的 `VaspTaskList.md`。

备份在服务器内部完成，不经过本机网络。本 skill 只做备份与登记，不提交、不监控、不取消作业；提交和计算流程仍由 `fang-ssh-skill` 负责。

## 核心约束

- 服务器必须由用户明确选择 `yang` 或 `lan`；不设置默认服务器。
- 一个任务只属于一个项目。开始新任务时先确认项目名（`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`）并运行 `scripts/new_vasp_project.ps1`，在当前目录写出 `.codex-vasp-project.json`。该文件记录服务器、项目名、工作根目录和本项目的远程目录清单，是“当前任务”的唯一依据。
- 备份只针对当前项目：只复制绑定文件列出的远程目录，不扫描、不猜测、不连带 `~/vasp_codex` 下的其他任务。
- 一个项目在 `/home/bak` 下只占一个文件夹 `/home/bak/<项目名>/`；每次备份在项目文件夹里新建 `<yyyyMMdd_HHmmss>` 子目录，同名子目录已存在时停止。不覆盖、不合并、不删除任何现有目录或文件，也不改动项目文件夹里用户自己放的内容。
- 未加 `-Yes` 时脚本只做只读检查或只打印计划；确认目标后才执行复制和日志写入。
- 日志写入使用 `flock` 加锁并在同目录原子替换，不重写或删除已有内容；同一任务ID再次备份时更新该行，不新增重复行。
- 任务日志写入要求备份主机提供 `flock`；缺失或无法原子替换时直接失败，不降级为并发不安全的原地覆盖。

## 备份根与日志路径

yang 和 lan 的项目都统一备份到**备份主机**（由 `config/servers.psd1` 的 `Common.Backup.Host` 指定，默认 `yang`）的 `/home/bak` 下：

- 一个项目一个文件夹：`/home/bak/<项目名>/`
- 每次备份进子目录：`/home/bak/<项目名>/<yyyyMMdd_HHmmss>/`
- 任务日志：`/home/bak/VaspTaskList.md`（全局一份，`服务器` 列标明项目在 yang 还是 lan）

项目在 yang 时整个复制在 yang 本机完成。项目在 lan 时，先用 `scp -3` 经本机中转把 `~/vasp_codex/<目录>` 从 lan 复制到 yang，再在源、目标两侧分别计算清单摘要（文件数、字节数、路径尺寸表摘要、SHA256 摘要）并比对，两侧一致才算 `verify=PASS`；因此 lan 自己的 `/home/bak` 不需要存在，也不需要额外授权。

注意：`/home/bak` 在备份主机上属于 root 目录，必须已存在且当前账号可写（yang 上是 777，已可用）。缺失或不可写时脚本拒绝执行并打印管理员命令，不要用 sudo 绕过，也不要静默改写到别处。临时替代是显式传 `-BackupRoot`、`-LogPath` 指向已存在的可写目录。跨服务器备份依赖本机 OpenSSH 的 `scp -3`；`-ExcludeLargeFiles` 目前只支持项目与备份主机在同一台机器的情况。

## 工作流

1. 确认服务器、项目名和属于本项目的远程目录；不清楚时先运行 `scripts/list_vasp_projects.ps1 -Server <yang|lan>` 展示远程任务目录、已有备份和日志文件，请用户确认归属。
2. 建立或复用项目绑定：

```powershell
$SkillRoot = Join-Path $HOME '.codex\skills\vasp_task_backup'
& "$SkillRoot/scripts/new_vasp_project.ps1" -Server yang -ProjectName mos2_u `
  -Source vasp_codex/mos2_u_relax,vasp_codex/mos2_u_scf,vasp_codex/mos2_u_band
```

3. 备份前必须先向用户收集“使用过程”和“计算结论”：这批计算用于做哪张图、哪个表，结论是什么。不要替用户编造结论；用户没给就写成“未填写”并说明。
4. 先看计划，再执行：

```powershell
# 只读检查：备份根可写性、源目录文件数和大小
& "$SkillRoot/scripts/backup_current_task.ps1"

# 备份并写入任务日志（推荐一次完成）
& "$SkillRoot/scripts/backup_and_log.ps1" -Yes `
  -Purpose '用于 2H-MoS2 能带图' -Conclusion 'PBE 带隙约 1.6 eV，间接带隙'
```

5. 需要把本机项目目录一并归档时加 `-LocalDirectory ./<本地项目目录>`；脚本会把本机目录上传到备份目录的 `local_project/` 子目录并做 SHA256 核对。
6. 想给本次备份一个可读后缀时加 `-Label <短名>`，子目录写成 `/home/bak/<项目名>/<时间戳>_<短名>/`。
7. 备份空间紧张时可用 `-ExcludeLargeFiles` 跳过 WAVECAR、CHGCAR；不确定时保持完整备份。
8. 只更新日志、不重新备份时使用 `scripts/update_task_log.ps1`。

## 报告要求

完成后报告：服务器、项目名、任务ID、项目文件夹与本次备份目录、文件数/大小、`verify` 结果、本机目录校验结果（如启用）、任务日志路径与本次是新增还是更新。目标子目录已存在、源目录缺失、备份根不可写、校验失败时都不得声称成功；校验失败时保留不完整目录并说明位置，不自动清理。

## 脚本

- `scripts/new_vasp_project.ps1`：建立当前任务的项目绑定，可选 `-CreateRemote` 创建缺失的远程目录。
- `scripts/backup_current_task.ps1`：备份当前项目的远程目录，可选归档本机项目目录。
- `scripts/update_task_log.ps1`：创建或更新服务器上的 `VaspTaskList.md`。
- `scripts/backup_and_log.ps1`：备份成功后写入任务日志。
- `scripts/list_vasp_projects.ps1`：列出远程任务目录、已有备份和日志文件。
- `scripts/select_server.ps1`、`scripts/check_ssh_hosts.ps1`：加载服务器配置、检查免密登录。
- `references/task-log-format.md`：日志字段定义、路径选择和并发写入规则，需要改日志格式时先读它。

## 服务器配置

`config/servers.psd1` 预置 yang/lan 的 SSH 别名和主机；只有本机需要覆盖时才复制 `config/servers.local.example.psd1` 为 `config/servers.local.psd1`。本 skill 依赖用户 SSH 配置中已存在 `yang-login`、`lan-login` 免密登录；缺失时让用户先完成 SSH 配置，不自动修改 SSH config。
