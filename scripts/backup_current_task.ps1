[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)]$Ignored)
throw 'backup_current_task.ps1 has been retired. Use scripts/backup_completed_tasks.ps1 with -Server and absolute -Path values.'
