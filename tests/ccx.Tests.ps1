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

function Invoke-ClaudishSmoke([string[]]$ClaudeArgs, [bool]$OutputRedirected) {
    $testDrive = Join-Path ([System.IO.Path]::GetTempPath()) "ccx-claudish-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testDrive | Out-Null
    try {
        $fakeClaude = Join-Path $testDrive 'claude.cmd'
        $capturePath = Join-Path $testDrive 'claude-args.txt'
        $environmentCapturePath = Join-Path $testDrive 'claude-env.txt'
        Set-Content -LiteralPath $fakeClaude -Encoding ascii -Value @'
@echo off
if defined OPENAI_API_KEY (
  >"%CCX_ENV_CAPTURE_PATH%" echo(present
) else (
  >"%CCX_ENV_CAPTURE_PATH%" echo(absent
)
:capture
if "%~1"=="" goto done
>>"%CCX_CAPTURE_PATH%" echo(%~1
shift
goto capture
:done
exit /b 0
'@

        $interactive = Test-CcxInteractive -ClaudeArgs $ClaudeArgs -OutputRedirected:$OutputRedirected
        $startInfo = New-ClaudishStartInfo `
            -BunPath (Get-Command bun -CommandType Application).Source `
            -ClaudishPath (Join-Path $root 'node_modules/claudish/dist/index.js') `
            -Model 'gpt-test' `
            -ClaudeArgs $ClaudeArgs `
            -OpenAIKey 'fake-openai-key' `
            -Interactive $interactive
        $startInfo.Environment['CLAUDE_PATH'] = $fakeClaude
        $startInfo.Environment['CCX_CAPTURE_PATH'] = $capturePath
        $startInfo.Environment['CCX_ENV_CAPTURE_PATH'] = $environmentCapturePath
        $startInfo.Environment['HOME'] = $testDrive
        $startInfo.Environment['USERPROFILE'] = $testDrive
        $startInfo.Environment['LOCALAPPDATA'] = $testDrive
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $script:CcxExitCode = $null
        $oldError = [Console]::Error
        $capturedError = [System.IO.StringWriter]::new()
        try {
            [Console]::SetError($capturedError)
            $processOutput = @(Invoke-ProcessStartInfo -StartInfo $startInfo)
        } finally {
            [Console]::SetError($oldError)
        }
        [pscustomobject]@{
            ExitCode = $script:CcxExitCode
            Interactive = $interactive
            ProcessOutput = $processOutput
            ProcessError = $capturedError.ToString()
            StartArgs = @($startInfo.ArgumentList)
            ClaudeArgs = @(Get-Content -LiteralPath $capturePath)
            OpenAIKeyPresent = (Get-Content -Raw -LiteralPath $environmentCapturePath).Trim() -eq 'present'
            UpdateCacheExists = Test-Path -LiteralPath (Join-Path $testDrive 'claudish/update-check.json')
        }
    } finally {
        Remove-Item -LiteralPath $testDrive -Recurse -Force
    }
}

Test-Case 'default model and all ordinary arguments are preserved' {
    $result = Split-CcxArguments -Arguments @('-p', 'hello world', '--output-format', 'text')
    Assert-Equal $result.Model 'gpt-5.6-sol' 'default model'
    Assert-Sequence @($result.ClaudeArgs) @('-p', 'hello world', '--output-format', 'text') 'Claude arguments'
}

Test-Case 'separate model flag is consumed' {
    $result = Split-CcxArguments -Arguments @('-p', 'prompt', '--model', 'gpt-test', '--verbose')
    Assert-Equal $result.Model 'gpt-test' 'selected model'
    Assert-Sequence @($result.ClaudeArgs) @('-p', 'prompt', '--verbose') 'Claude arguments'
}

Test-Case 'equals model flag is consumed' {
    $result = Split-CcxArguments -Arguments @('--model=gpt-test', '--verbose')
    Assert-Equal $result.Model 'gpt-test' 'selected model'
    Assert-Sequence @($result.ClaudeArgs) @('--verbose') 'Claude arguments'
}

Test-Case 'separator ends wrapper parsing and is not forwarded' {
    $result = Split-CcxArguments -Arguments @('--model', 'wrapper-model', '-p', 'prompt', '--', '--model', 'literal-model', '--flag=value')
    Assert-Equal $result.Model 'wrapper-model' 'wrapper model'
    Assert-Sequence @($result.ClaudeArgs) @('-p', 'prompt', '--model', 'literal-model', '--flag=value') 'literal Claude arguments'
}

Test-Case 'missing separate model value is rejected precisely' {
    Assert-Throws { Split-CcxArguments -Arguments @('--model') } 'Missing value for --model.' 'missing model error'
}

Test-Case 'separator cannot be a separate model value' {
    Assert-Throws { Split-CcxArguments -Arguments @('--model', '--') } 'Missing value for --model.' 'separator model error'
}

Test-Case 'empty separate model value is rejected precisely' {
    Assert-Throws { Split-CcxArguments -Arguments @('--model', '') } 'Model value for --model cannot be empty.' 'empty model error'
}

Test-Case 'empty equals model value is rejected precisely' {
    Assert-Throws { Split-CcxArguments -Arguments @('--model=') } 'Model value for --model cannot be empty.' 'empty equals model error'
}

Test-Case 'auth reader returns a fake key and rejects a missing key' {
    $testDrive = Join-Path ([System.IO.Path]::GetTempPath()) "ccx-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testDrive | Out-Null
    try {
        $fakeAuth = Join-Path $testDrive 'auth.json'
        Set-Content -LiteralPath $fakeAuth -Value '{"OPENAI_API_KEY":"fake-openai-key"}'
        Assert-Equal (Get-OpenAIKey -AuthPath $fakeAuth) 'fake-openai-key' 'fake key'

        Set-Content -LiteralPath $fakeAuth -Value '{"auth_mode":"chatgpt"}'
        Assert-Throws { Get-OpenAIKey -AuthPath $fakeAuth } "OPENAI_API_KEY is missing from $fakeAuth" 'missing key error'
    } finally {
        Remove-Item -LiteralPath $testDrive -Recurse -Force
    }
}

Test-Case 'Claudish start info has exact arguments and isolated environment' {
    $oldOpenAIKey = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'Process')
    $oldOpenAIBaseUrl = [Environment]::GetEnvironmentVariable('OPENAI_BASE_URL', 'Process')
    $oldAnthropicKey = [Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'Process')
    $oldAnthropicToken = [Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', 'parent-openai-key', 'Process')
        [Environment]::SetEnvironmentVariable('OPENAI_BASE_URL', 'https://parent.invalid', 'Process')
        [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', 'parent-anthropic-key', 'Process')
        [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'parent-anthropic-token', 'Process')

        $startInfo = New-ClaudishStartInfo `
            -BunPath 'C:\fake\bun.exe' `
            -ClaudishPath 'C:\fake\node_modules\claudish\dist\index.js' `
            -Model 'gpt-test' `
            -ClaudeArgs @('-p', 'hello world', '--output-format=text') `
            -OpenAIKey 'fake-openai-key' `
            -Interactive $false

        Assert-Equal $startInfo.FileName 'C:\fake\bun.exe' 'Bun executable'
        Assert-Sequence @($startInfo.ArgumentList) @(
            'C:\fake\node_modules\claudish\dist\index.js',
            '--model', 'oai@gpt-test',
            '--models-skip-update',
            '--log-off',
            '--log-diag', 'off',
            '--no-auto-approve',
            '--dangerously-skip-permissions',
            '--',
            '-p', 'hello world', '--output-format=text'
        ) 'Claudish arguments'
        Assert-True (-not $startInfo.UseShellExecute) 'shell execution is disabled'
        Assert-True (-not $startInfo.RedirectStandardInput) 'standard input is inherited'
        Assert-True $startInfo.RedirectStandardOutput 'standard output is redirected'
        Assert-True $startInfo.RedirectStandardError 'standard error is redirected'
        Assert-True (-not $startInfo.CreateNoWindow) 'the inherited console is retained'
        Assert-Equal $startInfo.Environment['OPENAI_API_KEY'] 'fake-openai-key' 'child OpenAI key'
        Assert-Equal $startInfo.Environment['OPENAI_BASE_URL'] 'https://api.openai.com' 'child OpenAI base URL'
        Assert-Equal $startInfo.Environment['CLAUDISH_STATS'] 'off' 'child usage stats setting'
        Assert-Equal $startInfo.Environment['CLAUDISH_TELEMETRY'] '0' 'child telemetry setting'
        Assert-True (-not $startInfo.Environment.ContainsKey('ANTHROPIC_API_KEY')) 'child Anthropic API key is removed'
        Assert-True (-not $startInfo.Environment.ContainsKey('ANTHROPIC_AUTH_TOKEN')) 'child Anthropic auth token is removed'
        Assert-True (-not (@($startInfo.ArgumentList) -contains 'fake-openai-key')) 'OpenAI key is absent from arguments'
        Assert-Equal ([Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'Process')) 'parent-openai-key' 'parent OpenAI key'
        Assert-Equal ([Environment]::GetEnvironmentVariable('OPENAI_BASE_URL', 'Process')) 'https://parent.invalid' 'parent OpenAI base URL'
        Assert-Equal ([Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'Process')) 'parent-anthropic-key' 'parent Anthropic key'
        Assert-Equal ([Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'Process')) 'parent-anthropic-token' 'parent Anthropic token'
    } finally {
        [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $oldOpenAIKey, 'Process')
        [Environment]::SetEnvironmentVariable('OPENAI_BASE_URL', $oldOpenAIBaseUrl, 'Process')
        [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $oldAnthropicKey, 'Process')
        [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $oldAnthropicToken, 'Process')
    }
}

Test-Case 'interactive Claudish start info inherits all console streams' {
    $startInfo = New-ClaudishStartInfo `
        -BunPath 'C:\fake\bun.exe' `
        -ClaudishPath 'C:\fake\node_modules\claudish\dist\index.js' `
        -Model 'gpt-test' `
        -ClaudeArgs @() `
        -OpenAIKey 'fake-openai-key' `
        -Interactive $true

    Assert-True (-not $startInfo.RedirectStandardInput) 'standard input is inherited'
    Assert-True (-not $startInfo.RedirectStandardOutput) 'standard output is inherited'
    Assert-True (-not $startInfo.RedirectStandardError) 'standard error is inherited'
}

Test-Case 'real Claudish keeps an empty attached invocation interactive without update cache' {
    $result = Invoke-ClaudishSmoke -ClaudeArgs @() -OutputRedirected:$false
    Assert-Equal $result.ExitCode 0 'Claudish smoke exit code'
    Assert-True $result.Interactive 'invocation classification'
    Assert-True ($result.StartArgs -contains '--interactive') 'explicit interactive flag'
    Assert-True ($result.StartArgs -contains '--json') 'interactive update-check suppression'
    Assert-True ($result.ClaudeArgs -contains '--dangerously-skip-permissions') 'Claude receives auto approval'
    Assert-True ($result.ClaudeArgs -notcontains '-p') 'Claudish does not force print mode'
    Assert-True ($result.ClaudeArgs -notcontains '--output-format') 'Claude JSON output is not forced'
    Assert-True (-not $result.OpenAIKeyPresent) 'Claude descendant does not inherit the OpenAI key'
    Assert-True (-not $result.UpdateCacheExists) 'update-check cache is absent'
}

Test-Case 'real Claudish keeps a flag-only attached invocation interactive' {
    $result = Invoke-ClaudishSmoke -ClaudeArgs @('--verbose') -OutputRedirected:$false
    Assert-True $result.Interactive 'invocation classification'
    Assert-True ($result.ClaudeArgs -contains '--verbose') 'flag is forwarded'
    Assert-True ($result.ClaudeArgs -notcontains '-p') 'Claudish does not force print mode'
}

Test-Case 'real Claudish keeps a positional attached invocation interactive' {
    $result = Invoke-ClaudishSmoke -ClaudeArgs @('start-here') -OutputRedirected:$false
    Assert-True $result.Interactive 'invocation classification'
    Assert-True ($result.ClaudeArgs -contains 'start-here') 'prompt is forwarded'
    Assert-True ($result.ClaudeArgs -notcontains '-p') 'Claudish does not force print mode'
}

Test-Case 'real Claudish keeps print invocation headless without forcing JSON' {
    $result = Invoke-ClaudishSmoke -ClaudeArgs @('-p', 'print this') -OutputRedirected:$false
    Assert-True (-not $result.Interactive) 'invocation classification'
    Assert-Equal @($result.ClaudeArgs | Where-Object { $_ -eq '-p' }).Count 1 'print flag count'
    Assert-True ($result.StartArgs -notcontains '--interactive') 'interactive flag is absent'
    Assert-True ($result.StartArgs -notcontains '--json') 'JSON control flag is absent'
    Assert-True ($result.ClaudeArgs -notcontains '--output-format') 'Claude JSON output is not forced'
}

Test-Case 'redirected stdout is classified as noninteractive' {
    Assert-True (-not (Test-CcxInteractive -ClaudeArgs @() -OutputRedirected:$true)) 'redirected invocation classification'
}

Test-Case 'real Claudish keeps an empty redirected invocation headless' {
    $result = Invoke-ClaudishSmoke -ClaudeArgs @() -OutputRedirected:$true
    Assert-True (-not $result.Interactive) 'invocation classification'
    Assert-True ($result.ClaudeArgs -contains '--print') 'print mode is explicit'
    Assert-True ($result.StartArgs -notcontains '--interactive') 'interactive flag is absent'
    Assert-True ($result.StartArgs -notcontains '--json') 'JSON control flag is absent'
}

Test-Case 'child process exit code is returned exactly' {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    foreach ($argument in @('-NoProfile', '-Command', 'exit 37')) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $script:CcxExitCode = $null
    $output = @(Invoke-ProcessStartInfo -StartInfo $startInfo)
    Assert-Equal $output.Count 0 'exit code is absent from stdout'
    Assert-Equal $script:CcxExitCode 37 'child exit code'
}

Test-Case 'headless process streams stdout incrementally and preserves stderr' {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoProfile',
        '-Command',
        '[Console]::Out.WriteLine("first"); Start-Sleep -Milliseconds 900; [Console]::Out.WriteLine("second"); [Console]::Error.WriteLine("native-stderr"); exit 23'
    )) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $oldError = [Console]::Error
    $capturedError = [System.IO.StringWriter]::new()
    $observed = [System.Collections.Generic.List[object]]::new()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:CcxExitCode = $null
    try {
        [Console]::SetError($capturedError)
        $output = @(Invoke-ProcessStartInfo -StartInfo $startInfo | ForEach-Object {
            $observed.Add([pscustomobject]@{ Value = $_; At = $stopwatch.ElapsedMilliseconds })
            $_
        })
    } finally {
        $stopwatch.Stop()
        [Console]::SetError($oldError)
    }

    Assert-Sequence $output @('first', 'second') 'headless stdout lines'
    Assert-Equal $script:CcxExitCode 23 'nonzero child exit code'
    Assert-True ($capturedError.ToString() -match 'native-stderr') 'native stderr is preserved'
    Assert-Equal $observed.Count 2 'observed stdout line count'
    Assert-True (($stopwatch.ElapsedMilliseconds - $observed[0].At) -gt 600) 'first line is observable before child exit'
    $capturedError.Dispose()
}

Test-Case 'process-tree cleanup terminates only the exact child' {
    $target = Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
    $sentinel = Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
    try {
        Stop-CcxProcessTree -Process $target
        Assert-True ($target.WaitForExit(5000)) 'target process exits'
        Assert-True (-not $sentinel.HasExited) 'unrelated process remains running'
    } finally {
        foreach ($process in @($target, $sentinel)) {
            if (-not $process.HasExited) {
                & taskkill.exe /PID ([string]$process.Id) /T /F 2>$null | Out-Null
            }
            $process.Dispose()
        }
    }
}

Test-Case 'dependency versions are pinned exactly' {
    $packagePath = Join-Path $root 'package.json'
    Assert-True (Test-Path -LiteralPath $packagePath) 'package.json exists'
    $package = Get-Content -Raw -LiteralPath $packagePath | ConvertFrom-Json
    Assert-Equal $package.packageManager 'bun@1.3.14' 'Bun pin'
    Assert-Equal $package.dependencies.claudish '7.15.0' 'Claudish pin'
    Assert-Equal @($package.dependencies.PSObject.Properties).Count 1 'dependency count'
    Assert-Equal $package.patchedDependencies.'claudish@7.15.0' 'patches/claudish@7.15.0.patch' 'Claudish patch registration'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'patches/claudish@7.15.0.patch')) 'Claudish patch exists'
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'bun.lock')) 'bun.lock exists'
}

Test-Case 'LiteLLM artifacts are absent' {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'litellm.yaml'))) 'litellm.yaml is removed'
    $gitignorePath = Join-Path $root '.gitignore'
    Assert-True (Test-Path -LiteralPath $gitignorePath) '.gitignore exists'
    $ignoreLines = @(Get-Content -LiteralPath $gitignorePath)
    Assert-True ($ignoreLines -contains 'node_modules/') 'dependencies are ignored'
    Assert-True ($ignoreLines -notcontains 'logs/') 'obsolete logs ignore is removed'
    $logFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'logs') -File -ErrorAction SilentlyContinue)
    Assert-Equal $logFiles.Count 0 'obsolete runtime logs are removed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'docs/superpowers/specs/2026-07-14-claude-code-openai-gateway-design.md'))) 'obsolete gateway design is removed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'docs/superpowers/plans/2026-07-14-claude-code-openai-gateway.md'))) 'obsolete gateway plan is removed'
    $launcher = Get-Content -Raw -LiteralPath $launcherPath
    Assert-True ($launcher -notmatch '(?i)litellm|bunx|uvx|Get-FreeTcpPort|Stop-GatewayProcesses') 'launcher contains no gateway code'
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($failures.Count) launcher contract test(s) failed."
}

'PASS: Claudish launcher contract'
