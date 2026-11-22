[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)]$Ignored)
throw 'Markdown task logs are retired. backups now update /home/bak/VaspLog.xlsx through scripts/backup_completed_tasks.ps1.'
