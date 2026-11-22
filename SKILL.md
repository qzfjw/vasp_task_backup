---
name: vasp-task-backup
description: 增量备份服务器上的 VASP 任务到 yang 的 /home/bak，按原绝对路径镜像，并把登记信息合并到 /home/bak/VaspLog.xlsx。任务要求包含 INCAR 和 POSCAR，OUTCAR 可选；OUTCAR 存在时仍校验正常结束和致命错误。用于用户要求备份 VASP 算例、归档任务、跳过未变化任务、重新备份修改过的任务或按 VaspLog.xlsx 格式登记任务时；不负责提交、监控、取消或修复 VASP 作业。
---

# VASP 任务增量备份

## 结果定义

本 skill 处理可识别的 VASP 任务目录：

- 任务目录中必须存在普通文件 `INCAR` 和 `POSCAR`。
- `OUTCAR` 可以缺失，例如计算完成后用户自行删除；缺少 `OUTCAR` 不影响备份和登记。
- 如果 `OUTCAR` 存在，其最后 256 KiB 必须包含 `General timing and accounting informations for this job`。
- 如果 `OUTCAR` 存在，最后 256 KiB 不含明确的致命错误迹象，例如 `ZBRENT: fatal error`、`VERY BAD NEWS! internal error`、`Error EDDDAV`、段错误。
- 缺少 `INCAR`/`POSCAR`，或现有 `OUTCAR` 未正常收尾、出现致命错误的任务只出现在报告中，不复制、不新增登记。

`WAVECAR`、`CHGCAR` 等大文件不默认排除，镜像备份保留任务目录中的全部内容。任务目录下如果还有另一个也满足上述条件的子任务，两者分别备份和登记。

## 路径规则

备份主机由 `config/servers.psd1` 指定，默认 `yang`。源服务器可为 `yang` 或 `lan`；源端绝对路径本身不能是 `/`、`/home`、`/home/bak` 或 `/home/bak/...`。

镜像目标为 `/home/bak` 加源路径去掉最前面的 `/home/`；不在 `/home` 下的路径去掉最前面的 `/`：

| 源服务器路径 | 备份主机路径 |
|---|---|
| `/home/qzxy/1-student/a` | `/home/bak/qzxy/1-student/a` |
| `/home/data/a/project` | `/home/bak/data/a/project` |
| `/data/yangjianhui_group/user/task` | `/home/bak/data/yangjianhui_group/user/task` |

目标目录就是当前版本，不再创建“项目名/时间戳”层。旧版本保存在 `/home/bak/.vasp_task_backup/versions/<server>/<任务键>/<时间>/`，不要手工把它当作当前任务目录。

## 执行流程

1. 确认服务器和一个或多个源绝对路径。不要猜测任务范围；用户只给一个父目录时才递归扫描其下任务。
2. 先运行只读计划：

```powershell
$SkillRoot = Join-Path $HOME '.codex\skills\vasp_task_backup'
& "$SkillRoot/scripts/backup_completed_tasks.ps1" `
  -Server yang `
  -Path /home/qzxy,/home/data/a `
  -DryRun
```

3. 向用户报告可备份任务数、新增/修改/未变化数量、发现的不可备份任务样例和目标路径。不要把“计划”说成已经备份。
4. 用户明确要求实际执行后加 `-Yes`：

```powershell
& "$SkillRoot/scripts/backup_completed_tasks.ps1" `
  -Server yang `
  -Path /home/qzxy,/home/data/a `
  -Yes
```

5. lan 任务默认经本机 OpenSSH `scp -3` 中转至 yang。跨主机时源端先打 tar 包并输出 SHA256/manifest，备份端验 SHA、安全解包、核对路径/类型/大小，再原子替换当前镜像。
6. 需要内容哈希检测时加 `-DeepCheck`。默认增量检测使用文件路径、类型、大小、mtime、ctime 和权限；`-DeepCheck` 还会对每个文件计算 SHA256，适合时间戳不可信的场景，但全量首次扫描明显更慢。

## 增量与替换

- 状态索引：`/home/bak/.vasp_task_backup/index.json`，键为“服务器 + 源绝对路径”。
- yang 和 lan 若出现完全相同的源绝对路径，会因镜像目标冲突而失败，必须先调整路径范围；不要覆盖另一台服务器的当前镜像。
- 未变化且镜像目录完整的任务跳过复制，但仍确保其在 `VaspLog.xlsx` 中存在；镜像缺失或被外部改动时会自动重建。
- 任务内容变化后重新备份到同一镜像路径，旧目录移入内部版本区。
- 新镜像先在 staging 中复制/解包和核对；成功后才原子替换目标。失败目录不登记。
- 源任务在复制或打包期间发生变化时立即中止该项，避免形成混合快照。
- Excel 更新使用 `/home/bak/VaspLog.xlsx.lock` 的 `flock` 排他锁和同目录原子替换，并保留最近 5 份内部备份。

## VaspLog.xlsx

唯一登记文件是备份主机上的 `/home/bak/VaspLog.xlsx`，工作表 `VaspLog`，表格名 `VaspLogTable`，列必须严格为：

`编号,关联任务编号,操作人,时间,计算说明,使用记录,任务所在文件夹`

更新规则：

- `任务所在文件夹` 是唯一键。已存在时更新原行，不追加重复行；编号保持不变。
- 新任务从当前最大编号继续递增。
- `操作人` 取任务目录 owner，`时间` 取任务关键文件的最新修改时间。
- `计算说明` 从 POSCAR/CONTCAR/POTCAR/OUTCAR 提取化学式，并结合 INCAR 与路径概括体系、任务类型和参数，不超过 100 字。
- `使用记录` 只写可验证信息，例如目录中的报告/论文文件名和可从任务类型推断的可分析性质。不得编造论文、报告或已得出的物理化学结论。
- `关联任务编号` 只记录最近一层任务祖先的直接子任务编号，多个编号用英文逗号分隔。该列写为真正的文本单元格，不能写成浮点数。

详细格式和 OOXML 更新规则见 `references/task-log-format.md`。

## 报告要求

完成后至少报告：服务器、扫描路径、可备份任务数、不可备份任务数、新增/修改/未变化数量、实际传输数量、目标路径、`VaspLog.xlsx` 是否新增/更新、失败项。任何 SHA 校验、解包核对、索引或 Excel 更新失败都不得声称成功。

## 脚本入口

- `scripts/backup_completed_tasks.ps1`：唯一推荐入口，负责计划、yang 本机执行和 lan 跨主机中转。
- `scripts/vasp_task_backup.py`：远端 Python CLI，只依赖 Python 3.9+ 标准库。
- `scripts/vasp_backup_common.py`：完整性判定、元数据、指纹和任务扫描原语。
- `scripts/vasp_backup_scan.py`：递归发现、增量索引和日志记录导出。
- `scripts/vasp_backup_store.py`：rsync/tar 镜像、SHA 校验、原子替换和版本保留。
- `scripts/vasp_xlsx_log.py`：不依赖 openpyxl 的 `VaspLog.xlsx` 并发安全更新器。
- `scripts/lib/VaspTaskBackup.psm1`：本机服务器配置和 SSH 公共函数。

`backup_current_task.ps1`、`backup_and_log.ps1`、`update_task_log.ps1` 是旧入口，不再实现新备份规则；不要用它们登记 Markdown 日志。需要清单辅助时仍可使用 `list_vasp_projects.ps1`，但它输出的旧目录布局不代表当前镜像规则。

## 前置条件

- 本机：Windows PowerShell 5.1 或 PowerShell 7，`ssh`/`scp` 在 PATH。
- SSH config 已配置 `yang-login`、`lan-login` 免密登录。
- yang：`/home/bak` 已存在且当前账号可写，并提供 `flock`、`rsync`、`tar`、`sha256sum`。
- 两台源服务器：Python 3.9+、`tar`；yang 本机流程还需要 `rsync`。不需要 `openpyxl`。

不要用 sudo 绕过目录权限，不要把登记文件降级为 Markdown，也不要修改已有 `VaspLog.xlsx` 的列顺序。
