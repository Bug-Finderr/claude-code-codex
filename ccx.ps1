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

function Get-ClaudishArguments {
    param(
        [Parameter(Mandatory)][string]$ClaudishPath,
        [Parameter(Mandatory)][string]$Model,
        [string[]]$ClaudeArgs = @()
    )

    $arguments = @(
        $ClaudishPath,
        '--model', "oai@$Model",
        '--models-skip-update',
        '--log-off',
        '--log-diag', 'off',
        '--no-auto-approve',
        '--dangerously-skip-permissions'
    )
    if ($ClaudeArgs -notcontains '-p' -and $ClaudeArgs -notcontains '--print') {
        $arguments += '--interactive', '--json'
    }
    $arguments += '--'
    $arguments += $ClaudeArgs
    $arguments
}

function Invoke-CcxCommand {
    param(
        [Parameter(Mandatory)][string]$BunPath,
        [string[]]$ClaudishArgs = @(),
        [Parameter(Mandatory)][string]$OpenAIKey
    )

    $environment = [ordered]@{
        OPENAI_API_KEY = $OpenAIKey
        OPENAI_BASE_URL = 'https://api.openai.com'
        CLAUDISH_STATS = 'off'
        CLAUDISH_TELEMETRY = '0'
        ANTHROPIC_API_KEY = $null
        ANTHROPIC_AUTH_TOKEN = $null
    }
    $savedEnvironment = @{}
    $script:CcxExitCode = 1

    try {
        foreach ($name in $environment.Keys) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
        }
        $PSNativeCommandUseErrorActionPreference = $false
        & $BunPath @ClaudishArgs
        $script:CcxExitCode = $LASTEXITCODE
    } finally {
        foreach ($name in $environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }
}

function Invoke-Ccx {
    param([string[]]$Arguments = @())

    $parsed = Split-CcxArguments -Arguments $Arguments
    $bun = Get-Command bun -CommandType Application -ErrorAction SilentlyContinue
    if (-not $bun) { throw 'Required command not found: bun' }

    $claudishPath = Join-Path $PSScriptRoot 'node_modules/claudish/dist/index.js'
    if (-not (Test-Path -LiteralPath $claudishPath)) {
        throw "Claudish is not installed. Run 'bun install' in $PSScriptRoot."
    }

    $claudishArgs = @(Get-ClaudishArguments `
        -ClaudishPath $claudishPath `
        -Model $parsed.Model `
        -ClaudeArgs $parsed.ClaudeArgs)
    Invoke-CcxCommand `
        -BunPath $bun.Source `
        -ClaudishArgs $claudishArgs `
        -OpenAIKey (Get-OpenAIKey -AuthPath (Join-Path $HOME '.codex/auth.json'))
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Ccx -Arguments $args
    exit $script:CcxExitCode
}
