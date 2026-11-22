# vasp-task-backup

Codex skill：从 `yang` 或 `lan` 扫描指定的绝对路径，把可识别的 VASP 任务备份到备份主机 `yang` 的 `/home/bak`，按原服务器绝对路径镜像，并把登记信息增量写入 `/home/bak/VaspLog.xlsx`。

## 核心行为

- **输入文件要求**：任务必须包含 `INCAR` 和 `POSCAR`。`OUTCAR` 可以缺失；如果存在，则仍要求尾部有 VASP 正常结束标记且无明确致命错误。
- **按绝对路径镜像**：
  - `/home/qzxy/a` → `/home/bak/qzxy/a`
  - `/home/data/a/b` → `/home/bak/data/a/b`
  - lan 的 `/data/group/user/c` → `/home/bak/data/group/user/c`
- **增量备份**：任务未修改且镜像完整时跳过；源任务修改或镜像缺失/被外部改动时重新备份到同一镜像路径。
- **保留旧版本**：被替换的旧目录放在 `/home/bak/.vasp_task_backup/versions/`。
- **统一登记 Excel**：只维护 `/home/bak/VaspLog.xlsx`，不再写 `VaspTaskList.md`。
- **无 openpyxl 依赖**：服务器系统 Python 3.9+ 标准库即可更新 xlsx。
- **跨主机校验**：lan 经本机 `scp -3` 中转；源端 tar + SHA256 + manifest，目标端复验后原子落地。

## 备份与登记判定

任务目录必须包含普通文件：

```text
INCAR
POSCAR
```

`OUTCAR` 是可选文件，例如计算完成后用户可能已将其删除；缺少 `OUTCAR` 时仍会备份目录并登记。若 `OUTCAR` 存在，则在最后 256 KiB 中查找：

```text
General timing and accounting informations for this job
```

以下情况会使任务进入“不可备份”报告，不复制、不新增登记：

- 缺少 `INCAR` 或 `POSCAR`。
- OUTCAR 没有正常结束标记。
- 尾部出现 `ZBRENT: fatal error`、`VERY BAD NEWS! internal error`、`Error EDDDAV`、段错误等明确致命标记。

## 前置条件

| 项 | 要求 |
|---|---|
| 本机 | Windows PowerShell 5.1 或 PowerShell 7 |
| OpenSSH | `ssh`、`scp` 在 PATH，支持 `scp -3` |
| 登录 | SSH config 已配置 `yang-login`、`lan-login` 公钥免密登录 |
| yang | `/home/bak` 已存在且当前账号可写；有 `flock`、`rsync`、`tar`、`sha256sum` |
| 源服务器 | Python 3.9+、`tar`；yang 本机流程还需要 `rsync` |
| Python 包 | 不需要 `openpyxl` 或 pandas |

以下命令应直接返回用户名而不是询问密码：

```powershell
ssh yang-login id -un
ssh lan-login id -un
```

## 使用

### 1. 只读计划

先不加 `-Yes`，或显式使用 `-DryRun`：

```powershell
$SkillRoot = Join-Path $HOME '.codex\skills\vasp_task_backup'
& "$SkillRoot/scripts/backup_completed_tasks.ps1" `
  -Server yang `
  -Path /home/qzxy,/home/data/a `
  -DryRun
```

计划会显示：

- 扫描路径
- 可备份任务数
- 新增、修改、未变化数量
- 不可备份任务及原因样例
- 每个需要备份任务的源路径和目标路径

### 2. 执行备份

```powershell
& "$SkillRoot/scripts/backup_completed_tasks.ps1" `
  -Server yang `
  -Path /home/qzxy,/home/data/a `
  -Yes
```

lan 示例：

```powershell
& "$SkillRoot/scripts/backup_completed_tasks.ps1" `
  -Server lan `
  -Path /data/yangjianhui_group/user/project `
  -Yes
```

默认参数：

- 备份根：`/home/bak`
- Excel：`/home/bak/VaspLog.xlsx`
- 状态索引：`/home/bak/.vasp_task_backup/index.json`

可显式覆盖：

```powershell
& "$SkillRoot/scripts/backup_completed_tasks.ps1" `
  -Server yang `
  -Path /home/qzxy/a `
  -BackupRoot /home/bak `
  -LogPath /home/bak/VaspLog.xlsx `
  -Yes
```

### 3. 深度内容检测

默认比较文件路径、类型、大小、mtime、ctime 和权限，能检测常规内容写入、替换、增删文件。需要进一步比较每个文件 SHA256 时：

```powershell
& "$SkillRoot/scripts/backup_completed_tasks.ps1" `
  -Server yang `
  -Path /home/qzxy/a `
  -DeepCheck `
  -Yes
```

首次全量使用 `-DeepCheck` 会读取所有任务文件的完整内容，大目录可能很慢；后续会复用未变化文件的已有哈希。

## 增量状态

内部目录结构：

```text
/home/bak/.vasp_task_backup/
├─ index.json                        当前任务状态索引
├─ index.json.journal                中断安全的增量状态日志
├─ staging/                          原子替换前暂存区
├─ versions/<server>/<key>/<time>/   历史版本
└─ log-backups/                      VaspLog.xlsx 最近 5 份备份
```

索引键同时包含服务器和源绝对路径，避免 yang/lan 相同路径互相覆盖。

如果两台服务器确实存在相同的源绝对路径，镜像目标会相同；脚本会直接失败，避免一台服务器覆盖另一台的当前镜像。此时应缩小扫描路径，或为其中一台显式使用不同的备份根。

首次遇到已有镜像目录但没有索引时：

- 若目录内容与源任务的文件路径、类型、大小一致，直接接管为已备份状态。
- 否则会先保留为内部历史版本，再写入当前版本。
- 非 VASP 目录不会自动覆盖。

## VaspLog.xlsx

工作表 `VaspLog`，表格 `VaspLogTable`，严格列：

```text
编号 | 关联任务编号 | 操作人 | 时间 | 计算说明 | 使用记录 | 任务所在文件夹
```

- 以 `任务所在文件夹` 为唯一键。
- 已存在任务更新原行，不重复追加。
- 新任务从当前最大编号继续。
- `关联任务编号` 只关联最近一层父任务的直接子任务，多个编号用英文逗号分隔。
- 该列始终写为 Excel 文本单元格，避免大编号显示成浮点数。
- `使用记录` 只写可验证的报告/论文文件名和可分析性质，不编造论文、报告或计算结论。

详见 `references/task-log-format.md`。

## lan 跨主机流程

1. 将备份状态索引下载到本机并上传 lan 临时目录。
2. lan 递归扫描可备份任务并判断 `new/changed/unchanged`。
3. 对需要传输的任务在 lan 执行 `tar`，生成 manifest 和归档 SHA256。
4. 使用本机 `scp -3` 从 lan 传到 yang 临时目录。
5. yang 复验归档 SHA256，安全解包，核对路径/类型/大小。
6. 原子替换镜像并写索引。
7. 将可备份任务的登记记录传到 yang，更新 `VaspLog.xlsx`。

任一步失败即停止；临时目录会在 finally 中清理，不登记未完成传输。

## 目录说明

```text
vasp_task_backup/
├─ SKILL.md
├─ README.md
├─ agents/openai.yaml
├─ config/
│  ├─ servers.psd1
│  ├─ servers.local.example.psd1
│  └─ rules/backup-rules.psd1
├─ references/task-log-format.md
└─ scripts/
   ├─ backup_completed_tasks.ps1
   ├─ vasp_task_backup.py
   ├─ vasp_backup_common.py
   ├─ vasp_backup_scan.py
   ├─ vasp_backup_store.py
   ├─ vasp_xlsx_log.py
   └─ lib/VaspTaskBackup.psm1
```

旧脚本 `backup_current_task.ps1`、`backup_and_log.ps1`、`update_task_log.ps1` 不再实现新的镜像和 Excel 规则，不要用于当前备份任务。

## 更新摘要

当前版本相较旧流程：

- 从“当前项目 + 时间戳目录”改为“任务绝对路径 + 固定镜像目录”。
- 从 `VaspTaskList.md` 改为 `VaspLog.xlsx` 原表增量更新。
- 处理包含 `INCAR` 和 `POSCAR` 的 VASP 任务目录；`OUTCAR` 可选，存在时仍校验正常结束和明确致命错误。
- 增加内容变化检测、旧版本保留、SHA256 校验、Excel 表格范围同步和文本关联编号。
