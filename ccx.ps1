$ErrorActionPreference = 'Stop'

function Get-OpenAIKey {
    param([Parameter(Mandatory)][string]$AuthPath)

    if (-not (Test-Path -LiteralPath $AuthPath)) { throw "Codex auth file not found: $AuthPath" }
    $auth = Get-Content -Raw -LiteralPath $AuthPath | ConvertFrom-Json
    if (-not $auth.OPENAI_API_KEY) { throw "OPENAI_API_KEY is missing from $AuthPath" }
    $auth.OPENAI_API_KEY
}

function New-GatewayToken {
    "sk-ccx-$([guid]::NewGuid().ToString('N'))"
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Stop-ProcessTree {
    param([System.Diagnostics.Process]$Process)

    if ($Process -and -not $Process.HasExited) {
        & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null
    }
}

function Invoke-Ccx {
    param([string[]]$ClaudeArgs)

    $root = $PSScriptRoot
    $configPath = Join-Path $root 'litellm.yaml'
    $authPath = Join-Path $HOME '.codex/auth.json'
    $logsPath = Join-Path $root 'logs'
    foreach ($command in 'claude', 'uvx') {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command not found: $command" }
    }
    if (-not (Test-Path -LiteralPath $configPath)) { throw "LiteLLM config not found: $configPath" }

    $openAIKey = Get-OpenAIKey -AuthPath $authPath
    $gatewayToken = New-GatewayToken
    $port = Get-FreeTcpPort
    $baseUrl = "http://127.0.0.1:$port"
    New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
    $logPath = Join-Path $logsPath "litellm-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log"

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command uvx).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('--python', '3.13', '--from', 'litellm[proxy]==1.92.0', 'litellm', '--config', $configPath, '--host', '127.0.0.1', '--port', [string]$port)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['OPENAI_API_KEY'] = $openAIKey
    $startInfo.Environment['LITELLM_MASTER_KEY'] = $gatewayToken

    $gateway = [System.Diagnostics.Process]::new()
    $gateway.StartInfo = $startInfo
    $savedEnvironment = @{}
    $claudeEnvironment = @{
        ANTHROPIC_BASE_URL = $baseUrl
        ANTHROPIC_AUTH_TOKEN = $gatewayToken
        ANTHROPIC_MODEL = 'gpt-5.6-sol'
        ANTHROPIC_DEFAULT_OPUS_MODEL = 'gpt-5.6-sol'
        ANTHROPIC_DEFAULT_SONNET_MODEL = 'gpt-5.6-sol'
        ANTHROPIC_DEFAULT_HAIKU_MODEL = 'gpt-5.6-sol'
        CLAUDE_CODE_SUBAGENT_MODEL = 'gpt-5.6-sol'
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = '1'
        CLAUDE_CODE_DISABLE_THINKING = '1'
        DISABLE_PROMPT_CACHING = '1'
    }

    try {
        if (-not $gateway.Start()) { throw 'LiteLLM failed to start' }
        $stdout = $gateway.StandardOutput.ReadToEndAsync()
        $stderr = $gateway.StandardError.ReadToEndAsync()

        $ready = $false
        for ($attempt = 0; $attempt -lt 120; $attempt++) {
            if ($gateway.HasExited) { break }
            try {
                Invoke-RestMethod -Uri "$baseUrl/v1/models" -Headers @{ Authorization = "Bearer $gatewayToken" } -TimeoutSec 2 | Out-Null
                $ready = $true
                break
            } catch {
                Start-Sleep -Milliseconds 500
            }
        }
        if (-not $ready) { throw "LiteLLM did not become ready. Log: $logPath" }

        foreach ($name in $claudeEnvironment.Keys) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $claudeEnvironment[$name], 'Process')
        }
        & claude --dangerously-skip-permissions --model gpt-5.6-sol @ClaudeArgs
        $script:CcxExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    } finally {
        foreach ($name in $claudeEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
        Stop-ProcessTree -Process $gateway
        if ($stdout) { $stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath $logPath }
        if ($stderr) { $stderr.GetAwaiter().GetResult() | Add-Content -LiteralPath $logPath }
        $openAIKey = $null
        $gatewayToken = $null
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:CcxExitCode = 1
    Invoke-Ccx -ClaudeArgs $args
    exit $script:CcxExitCode
}
