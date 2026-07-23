$ErrorActionPreference = 'Stop'

$event = [Console]::In.ReadToEnd() | ConvertFrom-Json
if ($event.tool_name -ne 'Agent' -or $event.tool_input.model -ne 'sonnet') { exit 0 }

$event.tool_input.PSObject.Properties.Remove('model')
@{
    hookSpecificOutput = @{
        hookEventName = 'PreToolUse'
        permissionDecision = 'allow'
        updatedInput = $event.tool_input
    }
} | ConvertTo-Json -Depth 10 -Compress
