$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$launcherPath = Join-Path $root 'ccx.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
}

function Assert-Sequence([object[]]$Actual, [object[]]$Expected, [string]$Message) {
    if ($Actual.Count -ne $Expected.Count) {
        throw "$Message (expected $($Expected.Count) items, got $($Actual.Count))"
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Actual[$index] -ne $Expected[$index]) {
            throw "$Message (item $index expected '$($Expected[$index])', got '$($Actual[$index])')"
        }
    }
}

function Assert-Throws([scriptblock]$Action, [string]$ExpectedMessage, [string]$Message) {
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -eq $ExpectedMessage) { return }
        throw "$Message (expected '$ExpectedMessage', got '$($_.Exception.Message)')"
    }
    throw "$Message (no error was thrown)"
}

function Test-Case([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        "PASS: $Name"
    } catch {
        $failures.Add("FAIL: $Name - $($_.Exception.Message)")
    }
}

. $launcherPath

$temporaryEnvironmentNames = @(
    'OPENAI_API_KEY',
    'OPENAI_BASE_URL',
    'OPENAI_CODEX_BASE_URL',
    'CLAUDISH_STATS',
    'CLAUDISH_TELEMETRY',
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_AUTH_TOKEN'
)

function Assert-EnvironmentRestoredAfterCommand([int]$ExitCode) {
    $original = @{}
    $parent = @{
        OPENAI_API_KEY = 'parent-openai-key'
        OPENAI_BASE_URL = 'https://parent.invalid'
        OPENAI_CODEX_BASE_URL = 'https://parent-codex.invalid'
        CLAUDISH_STATS = 'parent-stats'
        CLAUDISH_TELEMETRY = 'parent-telemetry'
        ANTHROPIC_API_KEY = 'parent-anthropic-key'
        ANTHROPIC_AUTH_TOKEN = 'parent-anthropic-token'
    }
    $savedNativePreference = $PSNativeCommandUseErrorActionPreference
    try {
        foreach ($name in $temporaryEnvironmentNames) {
            $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $parent[$name], 'Process')
        }
        $PSNativeCommandUseErrorActionPreference = $true
        $childScript = '$state = @([bool]$env:OPENAI_API_KEY, ($env:OPENAI_BASE_URL -eq "https://proxy.invalid"), ($env:CLAUDISH_STATS -eq "off"), ($env:CLAUDISH_TELEMETRY -eq "0"), ($env:ANTHROPIC_API_KEY -eq "parent-anthropic-key"), (-not [bool]$env:ANTHROPIC_AUTH_TOKEN)); [string]::Join("|", $state); exit $env:CCX_TEST_EXIT'
        $oldTestExit = $env:CCX_TEST_EXIT
        $env:CCX_TEST_EXIT = [string]$ExitCode
        try {
            $output = @(Invoke-CcxCommand `
                -BunPath (Join-Path $PSHOME 'pwsh.exe') `
                -ClaudishArgs @('-NoProfile', '-Command', $childScript) `
                -OpenAIKey 'fake-openai-key' `
                -OpenAIBaseUrl 'https://proxy.invalid')
        } finally {
            $env:CCX_TEST_EXIT = $oldTestExit
        }

        Assert-Sequence $output @('True|True|True|True|True|True') 'translator environment'
        Assert-Equal $script:CcxExitCode $ExitCode 'child exit code'
        Assert-True $PSNativeCommandUseErrorActionPreference 'caller native error preference is unchanged'
        foreach ($name in $temporaryEnvironmentNames) {
            Assert-Equal ([Environment]::GetEnvironmentVariable($name, 'Process')) $parent[$name] "restored $name"
        }
    } finally {
        $PSNativeCommandUseErrorActionPreference = $savedNativePreference
        foreach ($name in $temporaryEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
        }
    }
}

Test-Case 'default model and ordinary arguments are preserved' {
    $result = Split-CcxArguments -Arguments @('-p', 'hello world', '--output-format', 'text')
    Assert-Equal $result.Model 'gpt-6-astra' 'default model'
    Assert-Sequence @($result.ClaudeArgs) @('-p', 'hello world', '--output-format', 'text') 'Claude arguments'
}

Test-Case 'both model flag forms are consumed' {
    $separate = Split-CcxArguments -Arguments @('--model', 'model-a', '--verbose')
    $equals = Split-CcxArguments -Arguments @('--model=model-b', '--verbose')
    Assert-Equal $separate.Model 'model-a' 'separate model'
    Assert-Equal $equals.Model 'model-b' 'equals model'
    Assert-Sequence @($separate.ClaudeArgs) @('--verbose') 'separate model arguments'
    Assert-Sequence @($equals.ClaudeArgs) @('--verbose') 'equals model arguments'
}

Test-Case 'separator ends wrapper parsing' {
    $result = Split-CcxArguments -Arguments @('--model', 'wrapper-model', '--', '--model', 'literal-model')
    Assert-Equal $result.Model 'wrapper-model' 'wrapper model'
    Assert-Sequence @($result.ClaudeArgs) @('--model', 'literal-model') 'literal Claude arguments'
}

Test-Case 'missing and empty models are rejected precisely' {
    Assert-Throws { Split-CcxArguments -Arguments @('--model') } 'Missing value for --model.' 'missing model'
    Assert-Throws { Split-CcxArguments -Arguments @('--model', '--') } 'Missing value for --model.' 'separator model'
    Assert-Throws { Split-CcxArguments -Arguments @('--model', '') } 'Model value for --model cannot be empty.' 'empty model'
    Assert-Throws { Split-CcxArguments -Arguments @('--model=') } 'Model value for --model cannot be empty.' 'empty equals model'
}

Test-Case 'environment key takes precedence and auth file remains the fallback' {
    $testDrive = Join-Path ([System.IO.Path]::GetTempPath()) "ccx-auth-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testDrive | Out-Null
    $oldHome = $env:CODEX_HOME
    $oldKey = $env:OPENAI_API_KEY
    function Invoke-CcxCommand { param($BunPath, $ClaudishArgs, $OpenAIKey, $OpenAIBaseUrl) $OpenAIKey }
    try {
        $env:CODEX_HOME = $testDrive
        $fakeAuth = Join-Path $testDrive 'auth.json'
        Set-Content -LiteralPath $fakeAuth -Value '{"OPENAI_API_KEY":"fake-openai-key"}'
        $env:OPENAI_API_KEY = 'env-openai-key'
        Assert-Equal (Invoke-Ccx) 'env-openai-key' 'environment key'
        $env:OPENAI_API_KEY = ''
        Assert-Equal (Invoke-Ccx) 'fake-openai-key' 'auth file key'
        Set-Content -LiteralPath $fakeAuth -Value '{"auth_mode":"chatgpt"}'
        Assert-True ([string]::IsNullOrWhiteSpace((Invoke-Ccx))) 'ChatGPT auth needs no API key'
        Set-Content -LiteralPath $fakeAuth -Value '{bad json'
        $env:OPENAI_API_KEY = 'env-openai-key'
        Assert-Equal (Invoke-Ccx) 'env-openai-key' 'broken auth file does not block an environment key'
        $env:OPENAI_API_KEY = ''
        Assert-True ([string]::IsNullOrWhiteSpace((Invoke-Ccx))) 'broken auth file leaves Claudish login available'
    } finally {
        $env:CODEX_HOME = $oldHome
        $env:OPENAI_API_KEY = $oldKey
        Remove-Item -LiteralPath $testDrive -Recurse -Force
    }
}

Test-Case 'SDK-style OpenAI base URLs are normalized for Claudish' {
    Assert-Equal (Get-ClaudishOpenAIBaseUrl -BaseUrl '') 'https://api.openai.com' 'official fallback'
    Assert-Equal (Get-ClaudishOpenAIBaseUrl -BaseUrl 'https://proxy.invalid/v1/') 'https://proxy.invalid' 'SDK-style base URL'
    Assert-Equal (Get-ClaudishOpenAIBaseUrl -BaseUrl 'https://proxy.invalid/custom') 'https://proxy.invalid/custom' 'custom path'
}

Test-Case 'subscription routing keeps the requested model without an API key' {
    $arguments = @(Get-ClaudishArguments -ClaudishPath 'fake.js' -Model 'gpt-6-astra' -UseSubscription)
    Assert-Equal $arguments[2] 'cx@gpt-6-astra' 'ChatGPT route'
    $arguments = @(Get-ClaudishArguments -ClaudishPath 'fake.js' -Model 'gpt-test')
    Assert-Equal $arguments[2] 'oai@gpt-test' 'API route'
}

Test-Case 'Claudish arguments defer all modes to the patched actual-handle classifier' {
    foreach ($claudeArgs in @(@(), @('--verbose'), @('start-here'), @('--resume'), @('-p', 'prompt'), @('--print', 'prompt'))) {
        $arguments = @(Get-ClaudishArguments -ClaudishPath 'C:\fake\claudish.js' -Model 'gpt-test' -ClaudeArgs $claudeArgs)
        Assert-True ($arguments -notcontains '--interactive') 'interactive control flag is absent'
        Assert-True ($arguments -notcontains '--json') 'JSON control flag is absent'
        $preserveModels = [Array]::IndexOf($arguments, '--preserve-request-models')
        $dangerous = [Array]::IndexOf($arguments, '--dangerously-skip-permissions')
        $separator = [Array]::IndexOf($arguments, '--')
        Assert-True ($preserveModels -ge 0 -and $preserveModels -lt $separator) 'requested-model routing precedes separator'
        Assert-True ($dangerous -lt $separator) 'auto approval precedes separator'
        $forwarded = if ($separator + 1 -lt $arguments.Count) { @($arguments[($separator + 1)..($arguments.Count - 1)]) } else { @() }
        Assert-Sequence $forwarded $claudeArgs 'post-separator Claude arguments'
    }
}

Test-Case 'direct invocation streams capturable stdout and keeps exit code separate' {
    $childScript = '[Console]::Out.WriteLine("first"); Start-Sleep -Milliseconds 900; [Console]::Out.WriteLine("second"); exit 23'
    $observed = [System.Collections.Generic.List[object]]::new()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $output = @(Invoke-CcxCommand `
        -BunPath (Join-Path $PSHOME 'pwsh.exe') `
        -ClaudishArgs @('-NoProfile', '-Command', $childScript) `
        -OpenAIKey 'fake-openai-key' | ForEach-Object {
            $observed.Add([pscustomobject]@{ Value = $_; At = $stopwatch.ElapsedMilliseconds })
            $_
        })
    $stopwatch.Stop()

    Assert-Sequence $output @('first', 'second') 'captured stdout'
    Assert-Equal $script:CcxExitCode 23 'nonzero exit code'
    Assert-Equal $observed.Count 2 'observed line count'
    Assert-True (($stopwatch.ElapsedMilliseconds - $observed[0].At) -gt 600) 'first line is observable before exit'
}

Test-Case 'direct invocation leaves native stderr on the error stream' {
    $records = @(Invoke-CcxCommand `
        -BunPath (Join-Path $PSHOME 'pwsh.exe') `
        -ClaudishArgs @('-NoProfile', '-Command', '[Console]::Out.WriteLine("native-out"); [Console]::Error.WriteLine("native-err"); exit 19') `
        -OpenAIKey 'fake-openai-key' 2>&1)
    Assert-True (@($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.ToString() -eq 'native-err' }).Count -eq 1) 'native stderr record'
    Assert-True (@($records | Where-Object { $_ -is [string] -and $_ -eq 'native-out' }).Count -eq 1) 'native stdout record'
    Assert-Equal $script:CcxExitCode 19 'stderr command exit code'
}

Test-Case 'fake translator receives temporary environment restored after success' {
    Assert-EnvironmentRestoredAfterCommand -ExitCode 0
}

Test-Case 'temporary environment is restored after nonzero exit' {
    Assert-EnvironmentRestoredAfterCommand -ExitCode 29
}

Test-Case 'missing native command restores environment and retains failure exit' {
    $original = @{}
    $parentValue = 'parent-before-missing-command'
    try {
        foreach ($name in $temporaryEnvironmentNames) {
            $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $parentValue, 'Process')
        }
        $missingPath = Join-Path ([System.IO.Path]::GetTempPath()) "missing-bun-$([guid]::NewGuid().ToString('N')).exe"
        Assert-True (-not (Test-Path -LiteralPath $missingPath)) 'missing command fixture is absent'
        $script:CcxExitCode = 99
        $failed = $false
        try {
            Invoke-CcxCommand -BunPath $missingPath -ClaudishArgs @() -OpenAIKey 'fake-openai-key'
        } catch {
            $failed = $true
        }
        Assert-True $failed 'missing command throws'
        Assert-Equal $script:CcxExitCode 1 'missing command exit state'
        foreach ($name in $temporaryEnvironmentNames) {
            Assert-Equal ([Environment]::GetEnvironmentVariable($name, 'Process')) $parentValue "restored $name"
        }
    } finally {
        foreach ($name in $temporaryEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process')
        }
    }
}

foreach ($authMode in 'api', 'subscription', 'codex', 'codex-expired', 'missing', 'expired', 'unconfigured', 'expired-no-key') {
Test-Case "patched real Claudish routing and Claude child environment ($authMode)" {
    $useSubscription = $authMode -ne 'api'
    $expectAuthFailure = $authMode -in 'unconfigured', 'expired-no-key'
    $testDrive = Join-Path ([System.IO.Path]::GetTempPath()) "ccx-claudish-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testDrive | Out-Null
    $names = @('CLAUDE_PATH', 'HOME', 'USERPROFILE', 'LOCALAPPDATA', 'CODEX_HOME', 'CCX_TEST_AUTH_MODE', 'OPENAI_CODEX_API_KEY')
    $saved = @{}
    try {
        $fakeClaude = Join-Path $testDrive 'claude.cmd'
        $environmentCapturePath = Join-Path $testDrive 'claude-env.txt'
        $upstreamCapturePath = Join-Path $testDrive 'upstream-headers.json'
        $agentCapturePath = Join-Path $testDrive 'agent-inputs.json'
        $settingsCapturePath = Join-Path $testDrive 'claude-settings.json'
        $userSettingsPath = Join-Path $testDrive 'user-settings.json'
        $fakeRequestScript = Join-Path $testDrive 'request.js'
        $preloadScript = Join-Path $testDrive 'preload.js'
        Set-Content -LiteralPath $userSettingsPath -Value '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo user"}]}]},"statusLine":{"type":"command","command":"configured-statusline","padding":0}}'
        New-Item -ItemType Directory -Path (Join-Path $testDrive '.claude') | Out-Null
        Copy-Item -LiteralPath $userSettingsPath -Destination (Join-Path $testDrive '.claude/settings.json')
        Set-Content -LiteralPath $fakeRequestScript -Value @'
const response = await fetch(`${process.env.ANTHROPIC_BASE_URL}/v1/messages`, {
  method: "POST",
  headers: { "content-type": "application/json", authorization: "Bearer fake-oauth" },
  body: JSON.stringify({ model: "claude-fable-5", max_tokens: 1, messages: [{ role: "user", content: "OK" }] }),
});
if (!response.ok) process.exit(1);

const agentInput = async (model, effort = model === "sonnet" ? "low" : "max") => {
  const response = await fetch(`${process.env.ANTHROPIC_BASE_URL}/v1/messages`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: process.env.CLAUDISH_ACTIVE_MODEL_NAME,
      output_config: { effort },
      max_tokens: 64,
      stream: true,
      messages: [{ role: "user", content: `delegate ${model} ${effort}` }],
      tools: [{
        name: "Agent",
        description: "Delegate work",
        input_schema: { type: "object", properties: { model: { type: "string" } } },
      }],
    }),
  });
  const body = await response.text();
  if (["unconfigured", "expired-no-key"].includes(process.env.CCX_TEST_AUTH_MODE)) {
    if (response.ok) throw new Error("Missing subscription login was accepted");
    return null;
  }
  if (!response.ok) throw new Error(`Agent request failed (${response.status}): ${body}`);
  const deltas = body.split("\n")
    .filter((line) => line.startsWith("data: "))
    .map((line) => JSON.parse(line.slice(6)))
    .filter((event) => event.type === "content_block_delta" && event.delta.type === "input_json_delta")
    .map((event) => event.delta.partial_json);
  if (!deltas.length) throw new Error(`No Agent arguments: ${body}`);
  return JSON.parse(deltas.join(""));
};
await Bun.write(process.env.CCX_AGENT_CAPTURE_PATH, JSON.stringify([
  await agentInput("sonnet"),
  await agentInput("fable"),
  await agentInput("fable", "xhigh"),
]));
'@
        Set-Content -LiteralPath $preloadScript -Value @'
const realFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input.url;
  if (url === "https://auth.openai.com/oauth/token") return Response.json({ error: "invalid_grant" }, { status: 401 });
  if (url === "https://api.anthropic.com/v1/messages") {
    await Bun.write(process.env.CCX_UPSTREAM_CAPTURE_PATH, JSON.stringify(Object.fromEntries(new Headers(init.headers))));
    return Response.json({ id: "msg_test", type: "message", role: "assistant", model: "claude-fable-5", content: [{ type: "text", text: "OK" }], stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 } });
  }
  if (url === "https://api.openai.com/v1/responses" || url === "https://proxy.invalid/v1/responses" || url === "https://chatgpt.com/backend-api/codex/responses") {
    await Bun.write(process.env.CCX_AGENT_CAPTURE_PATH + ".request", url);
    const subscription = url.startsWith("https://chatgpt.com/");
    if (subscription !== ["subscription", "codex"].includes(process.env.CCX_TEST_AUTH_MODE)) throw new Error("Wrong billing route");
    const headers = new Headers(init.headers);
    const token = process.env.CCX_TEST_AUTH_MODE === "codex" ? `e30.${Buffer.from('{"exp":4102444800}').toString("base64url")}.fake` : "fake-subscription-token";
    if (subscription && (headers.get("authorization") !== `Bearer ${token}` || headers.get("chatgpt-account-id") !== "fake-account")) throw new Error("Missing subscription credentials");
    if (!subscription && headers.get("authorization") !== "Bearer fake-openai-key") throw new Error("Missing fallback API key");
    if (["missing", "expired"].includes(process.env.CCX_TEST_AUTH_MODE) && url !== "https://proxy.invalid/v1/responses") throw new Error("Fallback ignored custom base URL");
    const request = JSON.parse(init.body);
    if (request.model !== "gpt-6-astra") throw new Error("Requested model changed");
    const toolName = request.tools[0].name;
    if (request.tools[0].strict !== false || request.tools[0].parameters.required?.includes("model")) throw new Error("Optional tool arguments became mandatory");
    const model = JSON.stringify(request.input).includes("fable") ? "fable" : "sonnet";
    const effort = JSON.stringify(request.input).includes("xhigh") ? "xhigh" : model === "sonnet" ? "low" : "max";
    if (subscription && request.reasoning?.effort !== effort) throw new Error("Astra effort changed");
    const callId = `call_${model}`;
    const args = JSON.stringify({ description: "probe", prompt: "reply ok", model });
    const events = [
      { type: "response.output_item.added", item: { type: "function_call", id: `fc_${callId}`, call_id: callId, name: toolName } },
      { type: "response.function_call_arguments.delta", call_id: callId, delta: args },
      { type: "response.output_item.done", item: { type: "function_call", id: `fc_${callId}`, call_id: callId, name: toolName, arguments: args } },
      { type: "response.completed", response: { usage: { input_tokens: 10, output_tokens: 5 } } },
    ];
    return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", {
      headers: { "content-type": "text/event-stream" },
    });
  }
  return realFetch(input, init);
};
'@
        Set-Content -LiteralPath $fakeClaude -Encoding ascii -Value @'
@echo off
if defined OPENAI_API_KEY (
  >"%CCX_ENV_CAPTURE_PATH%" echo(openai-present
) else (
  >"%CCX_ENV_CAPTURE_PATH%" echo(openai-absent
)
if defined ANTHROPIC_API_KEY (
  >>"%CCX_ENV_CAPTURE_PATH%" echo(anthropic-key-present
) else (
  >>"%CCX_ENV_CAPTURE_PATH%" echo(anthropic-key-absent
)
if defined ANTHROPIC_AUTH_TOKEN (
  >>"%CCX_ENV_CAPTURE_PATH%" echo(anthropic-token-present
) else (
  >>"%CCX_ENV_CAPTURE_PATH%" echo(anthropic-token-absent
)
:args
if "%~1"=="" goto done
if /i "%~1"=="--settings" copy /y "%~2" "%CCX_SETTINGS_CAPTURE_PATH%" >nul
shift
goto args
:done
bun "%CCX_FAKE_REQUEST_SCRIPT%"
exit /b %ERRORLEVEL%
'@
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        $env:CLAUDE_PATH = $fakeClaude
        $env:HOME = $testDrive
        $env:USERPROFILE = $testDrive
        $env:LOCALAPPDATA = $testDrive
        $env:CODEX_HOME = Join-Path $testDrive '.codex'
        $env:CCX_TEST_AUTH_MODE = $authMode
        $env:OPENAI_CODEX_API_KEY = $null
        $claudishHome = Join-Path $testDrive '.claudish'
        New-Item -ItemType Directory -Path $claudishHome | Out-Null
        if ($authMode -like 'codex*') {
            New-Item -ItemType Directory -Path $env:CODEX_HOME | Out-Null
            $expiry = if ($authMode -eq 'codex-expired') { 1 } else { 4102444800 }
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("{`"exp`":$expiry}")).TrimEnd('=').Replace('+','-').Replace('/','_')
            Set-Content -LiteralPath (Join-Path $env:CODEX_HOME 'auth.json') -Value "{`"auth_mode`":`"chatgpt`",`"tokens`":{`"access_token`":`"e30.$payload.fake`",`"account_id`":`"fake-account`",`"refresh_token`":`"do-not-copy`"}}"
        } elseif ($authMode -notin 'missing', 'unconfigured') {
            $expiry = if ($authMode -like 'expired*') { 1 } else { 4102444800000 }
            Set-Content -LiteralPath (Join-Path $claudishHome 'codex-oauth.json') -Value "{`"access_token`":`"fake-subscription-token`",`"refresh_token`":`"fake-refresh`",`"expires_at`":$expiry,`"account_id`":`"fake-account`"}"
        }
        Set-Content -LiteralPath (Join-Path $claudishHome 'all-models.json') -Value '{"version":2,"lastUpdated":"2026-08-06T00:00:00.000Z","entries":[{"modelId":"gpt-6-astra","aliases":["gpt-6-astra"],"contextWindow":1050000,"aggregators":[{"provider":"openai","contextWindow":1050000}]}],"models":[]}'
        $oldCapturePath = $env:CCX_ENV_CAPTURE_PATH
        $oldSettingsCapturePath = $env:CCX_SETTINGS_CAPTURE_PATH
        $env:CCX_ENV_CAPTURE_PATH = $environmentCapturePath
        $env:CCX_SETTINGS_CAPTURE_PATH = $settingsCapturePath
        $oldUpstreamCapturePath = $env:CCX_UPSTREAM_CAPTURE_PATH
        $oldFakeRequestScript = $env:CCX_FAKE_REQUEST_SCRIPT
        $oldAgentCapturePath = $env:CCX_AGENT_CAPTURE_PATH
        $oldAnthropicApiKey = $env:ANTHROPIC_API_KEY
        $env:CCX_UPSTREAM_CAPTURE_PATH = $upstreamCapturePath
        $env:CCX_FAKE_REQUEST_SCRIPT = $fakeRequestScript
        $env:CCX_AGENT_CAPTURE_PATH = $agentCapturePath
        $env:ANTHROPIC_API_KEY = 'fake-anthropic-key'
        try {
            $claudishArgs = @('--preload', $preloadScript) + @(Get-ClaudishArguments `
                -ClaudishPath (Join-Path $root 'node_modules/claudish/dist/index.js') `
                -Model 'gpt-6-astra' `
                -UseSubscription:$useSubscription `
                -ClaudeArgs $(if ($authMode -eq 'api') { @('-p', 'smoke') } else { @('-p', 'smoke', '--settings', $userSettingsPath) }))
            $output = @(Invoke-CcxCommand `
                -BunPath (Get-Command bun -CommandType Application).Source `
                -ClaudishArgs $claudishArgs `
                -OpenAIKey $(if ($expectAuthFailure) { '' } else { 'fake-openai-key' }) `
                -OpenAIBaseUrl $(if ($authMode -in 'missing', 'expired') { 'https://proxy.invalid' } else { 'https://api.openai.com' }))
        } finally {
            $env:CCX_ENV_CAPTURE_PATH = $oldCapturePath
            $env:CCX_SETTINGS_CAPTURE_PATH = $oldSettingsCapturePath
            $env:CCX_UPSTREAM_CAPTURE_PATH = $oldUpstreamCapturePath
            $env:CCX_FAKE_REQUEST_SCRIPT = $oldFakeRequestScript
            $env:CCX_AGENT_CAPTURE_PATH = $oldAgentCapturePath
            $env:ANTHROPIC_API_KEY = $oldAnthropicApiKey
        }
        if ($authMode -eq 'unconfigured') {
            Assert-True ($script:CcxExitCode -ne 0) 'no login or API key blocks startup'
            Assert-True (-not (Test-Path -LiteralPath "$agentCapturePath.request")) 'no credentials means no upstream request'
            return
        }
        Assert-Equal $script:CcxExitCode 0 'Claudish smoke exit code'
        Assert-Equal $output.Count 0 'Claudish smoke stdout'
        Assert-Sequence @(Get-Content -LiteralPath $environmentCapturePath) @(
            'openai-absent',
            'anthropic-key-absent',
            'anthropic-token-absent'
        ) 'Claude child auth environment'
        $settings = Get-Content -LiteralPath $settingsCapturePath -Raw | ConvertFrom-Json
        Assert-True ($settings.disableClaudeAiConnectors -ne $true) 'Claudish does not disable connector discovery'
        Assert-True ($settings.forceLoginMethod -ne 'console') 'Claude login stays available for connectors'
        if ($authMode -ne 'api') {
            Assert-Equal $settings.hooks.PreToolUse.Count 1 'user hook survives settings merge'
            Assert-Equal $settings.hooks.PreToolUse[0].matcher 'Bash' 'user hook remains unchanged'
        }
        Assert-Equal $settings.statusLine.command 'configured-statusline' 'configured statusline replaces Claudish fallback'
        $upstreamHeaders = Get-Content -LiteralPath $upstreamCapturePath -Raw | ConvertFrom-Json
        Assert-Equal $upstreamHeaders.'x-api-key' 'fake-anthropic-key' 'configured API key reaches Anthropic'
        Assert-True (-not $upstreamHeaders.PSObject.Properties['authorization']) 'subscription OAuth does not override the API key'
        if ($expectAuthFailure) {
            Assert-True (-not (Test-Path -LiteralPath "$agentCapturePath.request")) 'failed refresh without an API key means no upstream request'
        } else {
            $agentInputs = Get-Content -LiteralPath $agentCapturePath -Raw | ConvertFrom-Json
            Assert-True (-not $agentInputs[0].PSObject.Properties['model']) 'default Sonnet Agent input inherits the routed main model'
            Assert-Equal $agentInputs[1].model 'fable' 'explicit Agent model is preserved'
        }
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Remove-Item -LiteralPath $testDrive -Recurse -Force
    }
}

}

Test-Case 'OpenAI Responses starts workflow usage from the current request' {
    $source = Get-Content -LiteralPath (Join-Path $root 'node_modules/claudish/dist/index.js') -Raw
    $ollamaStart = $source.IndexOf('function createOllamaJsonlStream')
    $responsesStart = $source.IndexOf('function createResponsesStreamHandler')
    $responsesEnd = $source.IndexOf('var init_openai_responses_sse', $responsesStart)
    Assert-True ($ollamaStart -ge 0 -and $responsesStart -gt $ollamaStart -and $responsesEnd -gt $responsesStart) 'stream handlers are present in the expected order'

    $ollama = $source.Substring($ollamaStart, $responsesStart - $ollamaStart)
    $responses = $source.Substring($responsesStart, $responsesEnd - $responsesStart)
    Assert-True ($source.Contains('initialInputTokens: Math.ceil(JSON.stringify(claudeRequest).length / 4)')) 'request token estimate is passed to the stream'
    Assert-True ($responses.Contains('usage: messageStartUsage(opts.initialInputTokens)')) 'Responses message_start uses the request estimate'
    Assert-True ($ollama.Contains('usage: messageStartUsage(opts.priorInputTokens)')) 'Ollama keeps upstream usage accounting'
}

Test-Case 'Claudish preserves mid-turn steering messages' {
    $source = Get-Content -LiteralPath (Join-Path $root 'node_modules/claudish/dist/index.js') -Raw
    Assert-True ($source.Contains('if (msg.role === "user" || msg.role === "system")')) 'mid-conversation system messages reach OpenAI'
}

Test-Case 'real Claudish passes redirected stdout handles to fake Claude under assignment and pipeline' {
    $testDrive = Join-Path ([System.IO.Path]::GetTempPath()) "ccx-handle-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testDrive | Out-Null
    $names = @('CLAUDE_PATH', 'HOME', 'USERPROFILE', 'LOCALAPPDATA', 'CCX_POWERSHELL_PATH')
    $saved = @{}
    try {
        $fakeClaude = Join-Path $testDrive 'claude.cmd'
        Set-Content -LiteralPath $fakeClaude -Encoding ascii -Value @'
@echo off
"%CCX_POWERSHELL_PATH%" -NoProfile -Command "[Console]::IsOutputRedirected"
exit /b %ERRORLEVEL%
'@
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        $env:CLAUDE_PATH = $fakeClaude
        $env:HOME = $testDrive
        $env:USERPROFILE = $testDrive
        $env:LOCALAPPDATA = $testDrive
        $env:CCX_POWERSHELL_PATH = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'

        $claudishArgs = @(Get-ClaudishArguments `
            -ClaudishPath (Join-Path $root 'node_modules/claudish/dist/index.js') `
            -Model 'gpt-test' `
            -ClaudeArgs @('--verbose'))
        $assigned = @(Invoke-CcxCommand `
            -BunPath (Get-Command bun -CommandType Application).Source `
            -ClaudishArgs $claudishArgs `
            -OpenAIKey 'fake-openai-key')
        Assert-Equal $script:CcxExitCode 0 'assignment exit code'
        Assert-Sequence $assigned @('True') 'assignment capture'

        $emptyArgs = @(Get-ClaudishArguments `
            -ClaudishPath (Join-Path $root 'node_modules/claudish/dist/index.js') `
            -Model 'gpt-test' `
            -ClaudeArgs @())
        $emptyAssigned = @(Invoke-CcxCommand `
            -BunPath (Get-Command bun -CommandType Application).Source `
            -ClaudishArgs $emptyArgs `
            -OpenAIKey 'fake-openai-key' 2>$null)
        Assert-Sequence $emptyAssigned @('True') 'empty assignment capture'
        Assert-Equal $script:CcxExitCode 0 'empty assignment exit code'

        $piped = @(Invoke-CcxCommand `
            -BunPath (Get-Command bun -CommandType Application).Source `
            -ClaudishArgs $claudishArgs `
            -OpenAIKey 'fake-openai-key' 2>$null | ForEach-Object { "pipe:$_" })
        Assert-Sequence $piped @('pipe:True') 'pipeline capture'
        Assert-Equal $script:CcxExitCode 0 'pipeline exit code'
        $source = Get-Content -LiteralPath (Join-Path $root 'node_modules/claudish/dist/index.js') -Raw
        Assert-True $source.Contains('if (cliConfig.interactive && !cliConfig.jsonOutput && !cliConfig.skipModelsUpdate)') 'skip flag suppresses the version check'
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Remove-Item -LiteralPath $testDrive -Recurse -Force
    }
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($failures.Count) launcher contract test(s) failed."
}

'PASS: direct Claudish launcher contract'
