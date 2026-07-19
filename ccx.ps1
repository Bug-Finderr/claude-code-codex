$ErrorActionPreference = 'Stop'

function Get-OpenAIKey {
    param([Parameter(Mandatory)][string]$AuthPath)

    if (-not (Test-Path -LiteralPath $AuthPath)) { throw "Codex auth file not found: $AuthPath" }
    $auth = Get-Content -Raw -LiteralPath $AuthPath | ConvertFrom-Json
    if (-not $auth.OPENAI_API_KEY) { throw "OPENAI_API_KEY is missing from $AuthPath" }
    $auth.OPENAI_API_KEY
}

function Split-CcxArguments {
    param([string[]]$Arguments = @())

    $model = 'gpt-5.6-sol'
    $claudeArgs = [System.Collections.Generic.List[string]]::new()
    $parseWrapperFlags = $true

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if ($parseWrapperFlags -and $argument -eq '--') {
            $parseWrapperFlags = $false
            continue
        }
        if ($parseWrapperFlags -and $argument -eq '--model') {
            if ($index + 1 -ge $Arguments.Count -or $Arguments[$index + 1] -eq '--') {
                throw 'Missing value for --model.'
            }
            $model = $Arguments[++$index]
            if ([string]::IsNullOrWhiteSpace($model)) { throw 'Model value for --model cannot be empty.' }
            continue
        }
        if ($parseWrapperFlags -and $argument.StartsWith('--model=')) {
            $model = $argument.Substring(8)
            if ([string]::IsNullOrWhiteSpace($model)) { throw 'Model value for --model cannot be empty.' }
            continue
        }
        $claudeArgs.Add($argument)
    }

    [pscustomobject]@{
        Model = $model
        ClaudeArgs = $claudeArgs.ToArray()
    }
}

function Test-CcxInteractive {
    param(
        [string[]]$ClaudeArgs = @(),
        [bool]$OutputRedirected = [Console]::IsOutputRedirected
    )

    -not $OutputRedirected -and $ClaudeArgs -notcontains '-p' -and $ClaudeArgs -notcontains '--print'
}

function New-ClaudishStartInfo {
    param(
        [Parameter(Mandatory)][string]$BunPath,
        [Parameter(Mandatory)][string]$ClaudishPath,
        [Parameter(Mandatory)][string]$Model,
        [string[]]$ClaudeArgs = @(),
        [Parameter(Mandatory)][string]$OpenAIKey,
        [Parameter(Mandatory)][bool]$Interactive
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $BunPath
    $startInfo.UseShellExecute = $false
    $claudishArgs = @(
        $ClaudishPath,
        '--model', "oai@$Model",
        '--models-skip-update',
        '--log-off',
        '--log-diag', 'off',
        '--no-auto-approve',
        '--dangerously-skip-permissions'
    )
    if ($Interactive) { $claudishArgs += '--interactive', '--json' }
    $claudishArgs += '--'
    if (-not $Interactive -and $ClaudeArgs.Count -eq 0) {
        $claudishArgs += '--print'
    } else {
        $claudishArgs += $ClaudeArgs
    }
    foreach ($argument in $claudishArgs) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['OPENAI_API_KEY'] = $OpenAIKey
    $startInfo.Environment['OPENAI_BASE_URL'] = 'https://api.openai.com'
    $startInfo.Environment['CLAUDISH_STATS'] = 'off'
    $startInfo.Environment['CLAUDISH_TELEMETRY'] = '0'
    [void]$startInfo.Environment.Remove('ANTHROPIC_API_KEY')
    [void]$startInfo.Environment.Remove('ANTHROPIC_AUTH_TOKEN')
    $startInfo
}

function Stop-CcxProcessTree {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)

    if ($Process.HasExited) { return }
    & taskkill.exe /PID ([string]$Process.Id) /T /F 2>$null | Out-Null
    if (-not $Process.WaitForExit(5000)) { throw "Failed to terminate child process $($Process.Id)." }
}

function Invoke-ProcessStartInfo {
    param([Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$StartInfo)

    $process = [System.Diagnostics.Process]::new()
    $started = $false
    try {
        $process.StartInfo = $StartInfo
        if (-not $process.Start()) { throw 'Claudish failed to start.' }
        $started = $true
        $process.WaitForExit()
        $process.ExitCode
    } finally {
        if ($started -and -not $process.HasExited) { Stop-CcxProcessTree -Process $process }
        $process.Dispose()
    }
}

function Invoke-Ccx {
    param([string[]]$Arguments = @())

    $parsed = Split-CcxArguments -Arguments $Arguments
    $interactive = Test-CcxInteractive -ClaudeArgs $parsed.ClaudeArgs
    $bun = Get-Command bun -CommandType Application -ErrorAction SilentlyContinue
    if (-not $bun) { throw 'Required command not found: bun' }

    $claudishPath = Join-Path $PSScriptRoot 'node_modules/claudish/dist/index.js'
    if (-not (Test-Path -LiteralPath $claudishPath)) {
        throw "Claudish is not installed. Run 'bun install' in $PSScriptRoot."
    }

    $openAIKey = Get-OpenAIKey -AuthPath (Join-Path $HOME '.codex/auth.json')
    $startInfo = New-ClaudishStartInfo `
        -BunPath $bun.Source `
        -ClaudishPath $claudishPath `
        -Model $parsed.Model `
        -ClaudeArgs $parsed.ClaudeArgs `
        -OpenAIKey $openAIKey `
        -Interactive $interactive
    Invoke-ProcessStartInfo -StartInfo $startInfo
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = Invoke-Ccx -Arguments $args
    exit $exitCode
}
