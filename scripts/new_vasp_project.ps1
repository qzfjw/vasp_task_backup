[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)]$Ignored)
throw 'Project bindings are no longer used by vasp-task-backup. Pass one or more absolute server paths with backup_completed_tasks.ps1 -Path.'
