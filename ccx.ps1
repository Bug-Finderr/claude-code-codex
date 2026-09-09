$ErrorActionPreference = 'Stop'

function Get-OpenAIKey {
    param(
        [Parameter(Mandatory)][string]$AuthPath,
        [AllowEmptyString()][string]$EnvironmentKey = $env:OPENAI_API_KEY
    )

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentKey)) { return $EnvironmentKey }
    if (-not (Test-Path -LiteralPath $AuthPath)) { return }
    $auth = Get-Content -Raw -LiteralPath $AuthPath | ConvertFrom-Json
    $auth.OPENAI_API_KEY
}

function Get-ClaudishOpenAIBaseUrl {
    param([AllowEmptyString()][string]$BaseUrl = $env:OPENAI_BASE_URL)

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return 'https://api.openai.com' }
    $BaseUrl.Trim().TrimEnd('/') -replace '/v1$', ''
}

function Split-CcxArguments {
    param([string[]]$Arguments = @())

    $model = 'gpt-6-astra'
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
        [switch]$UseSubscription,
        [string[]]$ClaudeArgs = @()
    )

    $arguments = @(
        $ClaudishPath,
        '--model', "$(if ($UseSubscription) { 'cx' } else { 'oai' })@$Model",
        '--models-skip-update',
        '--preserve-request-models',
        '--log-off',
        '--log-diag', 'off',
        '--no-auto-approve',
        '--dangerously-skip-permissions'
    )
    $arguments += '--'
    $arguments += $ClaudeArgs
    $arguments
}

function Invoke-CcxCommand {
    param(
        [Parameter(Mandatory)][string]$BunPath,
        [string[]]$ClaudishArgs = @(),
        [AllowEmptyString()][string]$OpenAIKey,
        [string]$OpenAIBaseUrl = 'https://api.openai.com'
    )

    $environment = [ordered]@{
        OPENAI_API_KEY = $OpenAIKey
        OPENAI_BASE_URL = $OpenAIBaseUrl
        CLAUDISH_STATS = 'off'
        CLAUDISH_TELEMETRY = '0'
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

    $openAIKey = Get-OpenAIKey -AuthPath (Join-Path $HOME '.codex/auth.json')
    if ([string]::IsNullOrWhiteSpace($openAIKey) -and -not (Test-Path -LiteralPath (Join-Path $HOME '.claudish/codex-oauth.json'))) {
        throw "Sign in to ChatGPT first: bun `"$claudishPath`" login codex"
    }
    $claudishArgs = @(Get-ClaudishArguments `
        -ClaudishPath $claudishPath `
        -Model $parsed.Model `
        -UseSubscription:([string]::IsNullOrWhiteSpace($openAIKey)) `
        -ClaudeArgs $parsed.ClaudeArgs)
    Invoke-CcxCommand `
        -BunPath $bun.Source `
        -ClaudishArgs $claudishArgs `
        -OpenAIKey $openAIKey `
        -OpenAIBaseUrl (Get-ClaudishOpenAIBaseUrl)
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Ccx -Arguments $args
    exit $script:CcxExitCode
}
