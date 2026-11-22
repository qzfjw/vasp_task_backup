[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)]$Ignored)
throw 'backup_and_log.ps1 has been retired. Use scripts/backup_completed_tasks.ps1 -Server <yang|lan> -Path </absolute/path> -Yes.'
