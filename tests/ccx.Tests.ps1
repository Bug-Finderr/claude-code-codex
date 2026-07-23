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
    'CLAUDISH_STATS',
    'CLAUDISH_TELEMETRY',
    'CCX_AGENT_MODEL_HOOK',
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_AUTH_TOKEN'
)

function Assert-EnvironmentRestoredAfterCommand([int]$ExitCode) {
    $original = @{}
    $parent = @{
        OPENAI_API_KEY = 'parent-openai-key'
        OPENAI_BASE_URL = 'https://parent.invalid'
        CLAUDISH_STATS = 'parent-stats'
        CLAUDISH_TELEMETRY = 'parent-telemetry'
        CCX_AGENT_MODEL_HOOK = 'parent-hook'
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
        $childScript = '$state = @([bool]$env:OPENAI_API_KEY, ($env:OPENAI_BASE_URL -eq "https://proxy.invalid"), ($env:CLAUDISH_STATS -eq "off"), ($env:CLAUDISH_TELEMETRY -eq "0"), ($env:CCX_AGENT_MODEL_HOOK -like "*agent-model-hook.ps1"), (-not [bool]$env:ANTHROPIC_API_KEY), (-not [bool]$env:ANTHROPIC_AUTH_TOKEN)); [string]::Join("|", $state); exit $env:CCX_TEST_EXIT'
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

        Assert-Sequence $output @('True|True|True|True|True|True|True') 'translator environment'
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
    Assert-Equal $result.Model 'gpt-5.6-sol' 'default model'
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
    try {
        $fakeAuth = Join-Path $testDrive 'auth.json'
        Set-Content -LiteralPath $fakeAuth -Value '{"OPENAI_API_KEY":"fake-openai-key"}'
        Assert-Equal (Get-OpenAIKey -AuthPath $fakeAuth -EnvironmentKey 'env-openai-key') 'env-openai-key' 'environment key'
        Assert-Equal (Get-OpenAIKey -AuthPath $fakeAuth -EnvironmentKey '') 'fake-openai-key' 'auth file key'
        Set-Content -LiteralPath $fakeAuth -Value '{"auth_mode":"chatgpt"}'
        Assert-Throws { Get-OpenAIKey -AuthPath $fakeAuth -EnvironmentKey '' } "OPENAI_API_KEY is missing from $fakeAuth" 'missing key'
    } finally {
        Remove-Item -LiteralPath $testDrive -Recurse -Force
    }
}

Test-Case 'SDK-style OpenAI base URLs are normalized for Claudish' {
    Assert-Equal (Get-ClaudishOpenAIBaseUrl -BaseUrl '') 'https://api.openai.com' 'official fallback'
    Assert-Equal (Get-ClaudishOpenAIBaseUrl -BaseUrl 'https://proxy.invalid/v1/') 'https://proxy.invalid' 'SDK-style base URL'
    Assert-Equal (Get-ClaudishOpenAIBaseUrl -BaseUrl 'https://proxy.invalid/custom') 'https://proxy.invalid/custom' 'custom path'
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

Test-Case 'patched real Claudish configures the Claude child environment' {
    $testDrive = Join-Path ([System.IO.Path]::GetTempPath()) "ccx-claudish-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testDrive | Out-Null
    $names = @('CLAUDE_PATH', 'HOME', 'USERPROFILE', 'LOCALAPPDATA')
    $saved = @{}
    try {
        $fakeClaude = Join-Path $testDrive 'claude.cmd'
        $environmentCapturePath = Join-Path $testDrive 'claude-env.txt'
        $settingsCapturePath = Join-Path $testDrive 'claude-settings.json'
        $userSettingsPath = Join-Path $testDrive 'user-settings.json'
        Set-Content -LiteralPath $userSettingsPath -Value '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo user"}]}]}}'
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
>>"%CCX_ENV_CAPTURE_PATH%" echo(context-window-%CLAUDE_CODE_MAX_CONTEXT_TOKENS%
:args
if "%~1"=="" goto done
if /i "%~1"=="--settings" copy /y "%~2" "%CCX_SETTINGS_CAPTURE_PATH%" >nul
shift
goto args
:done
exit /b 0
'@
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        $env:CLAUDE_PATH = $fakeClaude
        $env:HOME = $testDrive
        $env:USERPROFILE = $testDrive
        $env:LOCALAPPDATA = $testDrive
        $oldCapturePath = $env:CCX_ENV_CAPTURE_PATH
        $oldSettingsCapturePath = $env:CCX_SETTINGS_CAPTURE_PATH
        $env:CCX_ENV_CAPTURE_PATH = $environmentCapturePath
        $env:CCX_SETTINGS_CAPTURE_PATH = $settingsCapturePath
        try {
            $claudishArgs = @(Get-ClaudishArguments `
                -ClaudishPath (Join-Path $root 'node_modules/claudish/dist/index.js') `
                -Model 'gpt-5.6-sol' `
                -ClaudeArgs @('-p', 'smoke', '--settings', $userSettingsPath))
            $output = @(Invoke-CcxCommand `
                -BunPath (Get-Command bun -CommandType Application).Source `
                -ClaudishArgs $claudishArgs `
                -OpenAIKey 'fake-openai-key')
        } finally {
            $env:CCX_ENV_CAPTURE_PATH = $oldCapturePath
            $env:CCX_SETTINGS_CAPTURE_PATH = $oldSettingsCapturePath
        }
        Assert-Equal $script:CcxExitCode 0 'Claudish smoke exit code'
        Assert-Equal $output.Count 0 'Claudish smoke stdout'
        Assert-Sequence @(Get-Content -LiteralPath $environmentCapturePath) @(
            'openai-absent',
            'anthropic-key-absent',
            'anthropic-token-absent',
            'context-window-1050000'
        ) 'Claude child auth environment'
        $settings = Get-Content -LiteralPath $settingsCapturePath -Raw | ConvertFrom-Json
        Assert-Equal $settings.hooks.PreToolUse.Count 2 'user and ccx hooks survive settings merge'
        Assert-Sequence @($settings.hooks.PreToolUse.matcher) @('Bash', 'Agent') 'settings hook order'
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Remove-Item -LiteralPath $testDrive -Recurse -Force
    }
}

Test-Case 'OpenAI Responses starts workflow usage from the current request' {
    $source = Get-Content -LiteralPath (Join-Path $root 'node_modules/claudish/dist/index.js') -Raw
    Assert-True ($source.Contains('initialInputTokens: estimateTokens(JSON.stringify(claudeRequest))')) 'request token estimate is passed to the stream'
    Assert-True ($source.Contains('usage: { input_tokens: opts.initialInputTokens, output_tokens: 1 }')) 'message_start uses the request estimate'
}

Test-Case 'Claudish installs the ccx Agent model hook' {
    $source = Get-Content -LiteralPath (Join-Path $root 'node_modules/claudish/dist/index.js') -Raw
    Assert-True ($source.Contains('const agentModelHook = process.env.CCX_AGENT_MODEL_HOOK;')) 'hook path is read from the ccx environment'
}

Test-Case 'Agent model hook inherits Sonnet and preserves explicit native models' {
    $hook = Join-Path $root 'agent-model-hook.ps1'
    Assert-True (Test-Path -LiteralPath $hook) 'Agent model hook exists'

    $sonnet = '{"tool_name":"Agent","tool_input":{"description":"probe","prompt":"reply ok","subagent_type":"general-purpose","model":"sonnet"}}' | & pwsh -NoProfile -File $hook | ConvertFrom-Json
    Assert-True (-not $sonnet.hookSpecificOutput.updatedInput.PSObject.Properties['model']) 'Sonnet override is removed'
    Assert-Equal $sonnet.hookSpecificOutput.updatedInput.prompt 'reply ok' 'other Agent input is preserved'

    foreach ($model in 'fable', 'opus') {
        $output = @('{"tool_name":"Agent","tool_input":{"model":"' + $model + '"}}' | & pwsh -NoProfile -File $hook)
        Assert-Equal $output.Count 0 "$model passes through unchanged"
    }
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
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $testDrive 'claudish/update-check.json'))) 'update-check cache is absent'
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
