# Claude Code OpenAI Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an isolated `ccx` PowerShell command that runs Claude Code against OpenAI `gpt-5.6-sol` through a temporary localhost LiteLLM gateway.

**Architecture:** A small YAML file maps the Claude-facing model ID to OpenAI. A PowerShell launcher reads the existing Codex key into memory, starts a pinned LiteLLM child process on an ephemeral loopback port, scopes Claude gateway variables to the invocation, and guarantees cleanup. The dotfiles profile only forwards `ccx` to the launcher.

**Tech Stack:** PowerShell 7, Claude Code 2.1.207+, `uvx`, Python 3.13, LiteLLM 1.92.0, YAML, Git

---

## File Map

- Create `D:/Files/Dev/ccx/litellm.yaml`: one-model gateway routing with environment-backed secrets.
- Create `D:/Files/Dev/ccx/ccx.ps1`: prerequisite checks, child-process environment, gateway lifecycle, Claude invocation, and cleanup.
- Create `D:/Files/Dev/ccx/tests/ccx.Tests.ps1`: dependency-free PowerShell assertions for configuration, credential validation, and process cleanup helpers.
- Modify `D:/Files/Dev/configs/windows/powershell/Microsoft.PowerShell_profile.ps1`: add the forwarding `ccx` function without changing existing user edits.

### Task 1: Gateway Configuration

**Files:**
- Create: `D:/Files/Dev/ccx/litellm.yaml`
- Test: `D:/Files/Dev/ccx/tests/ccx.Tests.ps1`

- [ ] **Step 1: Write the failing configuration test**

Create the test harness with this initial content:

```powershell
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $root 'litellm.yaml'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

Assert-True (Test-Path $configPath) 'litellm.yaml exists'
$config = Get-Content -Raw $configPath
Assert-True ($config -match 'model_name:\s*gpt-5\.6-sol') 'public model name is mapped'
Assert-True ($config -match 'model:\s*openai/gpt-5\.6-sol') 'OpenAI provider model is configured'
Assert-True ($config -match 'api_key:\s*os\.environ/OPENAI_API_KEY') 'API key comes from the environment'
Assert-True ($config -match 'master_key:\s*os\.environ/LITELLM_MASTER_KEY') 'gateway key comes from the environment'
Assert-True ($config -notmatch 'sk-[A-Za-z0-9_-]{12,}') 'no key is persisted in YAML'

'PASS: gateway configuration'
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `pwsh -NoProfile -File D:/Files/Dev/ccx/tests/ccx.Tests.ps1`

Expected: failure containing `FAIL: litellm.yaml exists`.

- [ ] **Step 3: Add the minimal LiteLLM configuration**

Create `litellm.yaml`:

```yaml
model_list:
  - model_name: gpt-5.6-sol
    litellm_params:
      model: openai/gpt-5.6-sol
      api_key: os.environ/OPENAI_API_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  disable_spend_logs: true
```

- [ ] **Step 4: Run the test and verify it passes**

Run: `pwsh -NoProfile -File D:/Files/Dev/ccx/tests/ccx.Tests.ps1`

Expected: `PASS: gateway configuration` and exit code 0.

- [ ] **Step 5: Commit the gateway configuration**

```powershell
git -C D:/Files/Dev/ccx add litellm.yaml tests/ccx.Tests.ps1
git -C D:/Files/Dev/ccx commit -m 'feat: configure GPT 5.6 sol gateway'
```

### Task 2: Isolated Launcher

**Files:**
- Create: `D:/Files/Dev/ccx/ccx.ps1`
- Modify: `D:/Files/Dev/ccx/tests/ccx.Tests.ps1`

This task exercises the fake credential path entirely offline before the real API key is used.

- [ ] **Step 1: Add failing launcher helper tests**

Append these assertions to `tests/ccx.Tests.ps1` before the final PASS output:

```powershell
$launcherPath = Join-Path $root 'ccx.ps1'
Assert-True (Test-Path $launcherPath) 'ccx.ps1 exists'
. $launcherPath

$testDrive = Join-Path ([System.IO.Path]::GetTempPath()) "ccx-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testDrive | Out-Null
try {
    $fakeAuth = Join-Path $testDrive 'auth.json'
    Set-Content -LiteralPath $fakeAuth -Value '{"OPENAI_API_KEY":"fake-openai-key"}'
    Assert-True ((Get-OpenAIKey -AuthPath $fakeAuth) -eq 'fake-openai-key') 'key is read from auth JSON'

    Set-Content -LiteralPath $fakeAuth -Value '{"auth_mode":"chatgpt"}'
    $missingKeyFailed = $false
    try { Get-OpenAIKey -AuthPath $fakeAuth } catch { $missingKeyFailed = $_.Exception.Message -match 'OPENAI_API_KEY' }
    Assert-True $missingKeyFailed 'missing key produces a precise error'
} finally {
    Remove-Item -LiteralPath $testDrive -Recurse -Force
}

$token = New-GatewayToken
Assert-True ($token -match '^sk-ccx-[a-f0-9]{32}$') 'gateway token has the required prefix and entropy'

$port = Get-FreeTcpPort
Assert-True ($port -ge 1024 -and $port -le 65535) 'ephemeral port is valid'
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `pwsh -NoProfile -File D:/Files/Dev/ccx/tests/ccx.Tests.ps1`

Expected: failure containing `FAIL: ccx.ps1 exists`.

- [ ] **Step 3: Implement the launcher**

Create `ccx.ps1` with these functions and entry point:

```powershell
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
    $requiredCommands = 'claude', 'uvx'
    foreach ($command in $requiredCommands) {
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
    foreach ($argument in @('--python','3.13','--from','litellm[proxy]==1.92.0','litellm','--config',$configPath,'--host','127.0.0.1','--port',[string]$port)) {
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
        if ($null -eq $LASTEXITCODE) { return 0 }
        $LASTEXITCODE
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
    exit (Invoke-Ccx -ClaudeArgs $args)
}
```

- [ ] **Step 4: Run syntax and helper tests**

Run:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile('D:/Files/Dev/ccx/ccx.ps1', [ref]$null, [ref]$errors) | Out-Null
if ($errors) { $errors; exit 1 }
pwsh -NoProfile -File D:/Files/Dev/ccx/tests/ccx.Tests.ps1
```

Expected: no parser errors, `PASS: gateway configuration`, and exit code 0.

- [ ] **Step 5: Commit the launcher**

```powershell
git -C D:/Files/Dev/ccx add ccx.ps1 tests/ccx.Tests.ps1
git -C D:/Files/Dev/ccx commit -m 'feat: add isolated ccx launcher'
```

### Task 3: PowerShell Profile Integration

**Files:**
- Modify: `D:/Files/Dev/configs/windows/powershell/Microsoft.PowerShell_profile.ps1:26`

- [ ] **Step 1: Verify the command is initially absent**

Run: `rg -n '^function ccx\b' D:/Files/Dev/configs/windows/powershell/Microsoft.PowerShell_profile.ps1`

Expected: no match and exit code 1.

- [ ] **Step 2: Add the forwarding function**

Append alongside the existing `cx` and `cc` functions:

```powershell
function ccx { & 'D:/Files/Dev/ccx/ccx.ps1' @args }
```

- [ ] **Step 3: Parse and load the profile in an isolated shell**

Run:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile('D:/Files/Dev/configs/windows/powershell/Microsoft.PowerShell_profile.ps1', [ref]$null, [ref]$errors) | Out-Null
if ($errors) { $errors; exit 1 }
pwsh -NoProfile -Command ". 'D:/Files/Dev/configs/windows/powershell/Microsoft.PowerShell_profile.ps1'; (Get-Command ccx).CommandType"
```

Expected: no parser errors and `Function`.

- [ ] **Step 4: Commit only the profile change without disturbing existing edits**

Inspect `git -C D:/Files/Dev/configs diff -- windows/powershell/Microsoft.PowerShell_profile.ps1`. Stage only the `ccx` hunk with a generated patch if other user changes remain, then commit that staged hunk as `feat: add ccx PowerShell command`.

### Task 4: End-to-End Verification

**Files:**
- Inspect: `D:/Files/Dev/ccx/logs/*.log`

- [ ] **Step 1: Run all offline checks**

Run:

```powershell
pwsh -NoProfile -File D:/Files/Dev/ccx/tests/ccx.Tests.ps1
git -C D:/Files/Dev/ccx grep -nE 'sk-[A-Za-z0-9_-]{12,}' -- ':!docs/superpowers/**'
```

Expected: tests pass; secret scan produces no matches.

- [ ] **Step 2: Run a minimal real Claude Code request**

Run:

```powershell
& 'D:/Files/Dev/ccx/ccx.ps1' -p 'Reply with exactly: CCX_OK' --output-format text
```

Expected: `CCX_OK` and exit code 0. This controlled request proves Claude Code, the Anthropic-compatible gateway, the existing OpenAI key, and `gpt-5.6-sol` work together.

- [ ] **Step 3: Verify cleanup and secret handling**

Run:

```powershell
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'litellm.*D:[/\\]Files[/\\]Dev[/\\]ccx' }
rg -n 'OPENAI_API_KEY\s*[:=]\s*sk-|Authorization:\s*Bearer\s+sk-' D:/Files/Dev/ccx
```

Expected: no matching LiteLLM process and no persisted OpenAI or bearer token.

- [ ] **Step 4: Review repository state**

Run:

```powershell
git -C D:/Files/Dev/ccx status --short
git -C D:/Files/Dev/ccx log --oneline -4
git -C D:/Files/Dev/ccx remote -v
```

Expected: clean `ccx` worktree and the design/configuration/launcher commits. If no remote is listed, report that pushing is unavailable rather than inventing one.
