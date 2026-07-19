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

function Assert-EnvironmentRestoredAfterCommand([int]$ExitCode) {
    $names = @(
        'OPENAI_API_KEY',
        'OPENAI_BASE_URL',
        'CLAUDISH_STATS',
        'CLAUDISH_TELEMETRY',
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_AUTH_TOKEN'
    )
    $original = @{}
    $parent = @{
        OPENAI_API_KEY = 'parent-openai-key'
        OPENAI_BASE_URL = 'https://parent.invalid'
        CLAUDISH_STATS = 'parent-stats'
        CLAUDISH_TELEMETRY = 'parent-telemetry'
        ANTHROPIC_API_KEY = 'parent-anthropic-key'
        ANTHROPIC_AUTH_TOKEN = 'parent-anthropic-token'
    }
    $savedNativePreference = $PSNativeCommandUseErrorActionPreference
    try {
        foreach ($name in $names) {
            $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $parent[$name], 'Process')
        }
        $PSNativeCommandUseErrorActionPreference = $true
        $childScript = '$state = @([bool]$env:OPENAI_API_KEY, ($env:OPENAI_BASE_URL -eq "https://api.openai.com"), ($env:CLAUDISH_STATS -eq "off"), ($env:CLAUDISH_TELEMETRY -eq "0"), (-not [bool]$env:ANTHROPIC_API_KEY), (-not [bool]$env:ANTHROPIC_AUTH_TOKEN)); [string]::Join("|", $state); exit $env:CCX_TEST_EXIT'
        $oldTestExit = $env:CCX_TEST_EXIT
        $env:CCX_TEST_EXIT = [string]$ExitCode
        try {
            $output = @(Invoke-CcxCommand `
                -BunPath (Join-Path $PSHOME 'pwsh.exe') `
                -ClaudishArgs @('-NoProfile', '-Command', $childScript) `
                -OpenAIKey 'fake-openai-key')
        } finally {
            $env:CCX_TEST_EXIT = $oldTestExit
        }

        Assert-Sequence $output @('True|True|True|True|True|True') 'translator environment'
        Assert-Equal $script:CcxExitCode $ExitCode 'child exit code'
        Assert-True $PSNativeCommandUseErrorActionPreference 'caller native error preference is unchanged'
        foreach ($name in $names) {
            Assert-Equal ([Environment]::GetEnvironmentVariable($name, 'Process')) $parent[$name] "restored $name"
        }
    } finally {
        $PSNativeCommandUseErrorActionPreference = $savedNativePreference
        foreach ($name in $names) {
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

Test-Case 'auth reader uses only the configured fake key' {
    $testDrive = Join-Path ([System.IO.Path]::GetTempPath()) "ccx-auth-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testDrive | Out-Null
    try {
        $fakeAuth = Join-Path $testDrive 'auth.json'
        Set-Content -LiteralPath $fakeAuth -Value '{"OPENAI_API_KEY":"fake-openai-key"}'
        Assert-Equal (Get-OpenAIKey -AuthPath $fakeAuth) 'fake-openai-key' 'fake key'
        Set-Content -LiteralPath $fakeAuth -Value '{"auth_mode":"chatgpt"}'
        Assert-Throws { Get-OpenAIKey -AuthPath $fakeAuth } "OPENAI_API_KEY is missing from $fakeAuth" 'missing key'
    } finally {
        Remove-Item -LiteralPath $testDrive -Recurse -Force
    }
}

Test-Case 'interactive Claudish arguments preserve attached modes' {
    foreach ($claudeArgs in @(@(), @('--verbose'), @('start-here'), @('--resume'))) {
        $arguments = @(Get-ClaudishArguments -ClaudishPath 'C:\fake\claudish.js' -Model 'gpt-test' -ClaudeArgs $claudeArgs)
        Assert-True ($arguments -contains '--interactive') 'interactive control flag'
        Assert-True ($arguments -contains '--json') 'update-check suppression flag'
        $dangerous = [Array]::IndexOf($arguments, '--dangerously-skip-permissions')
        $separator = [Array]::IndexOf($arguments, '--')
        Assert-True ($dangerous -lt $separator) 'auto approval precedes separator'
        $forwarded = if ($separator + 1 -lt $arguments.Count) { @($arguments[($separator + 1)..($arguments.Count - 1)]) } else { @() }
        Assert-Sequence $forwarded $claudeArgs 'post-separator Claude arguments'
    }
}

Test-Case 'print Claudish arguments remain headless' {
    foreach ($printFlag in @('-p', '--print')) {
        $arguments = @(Get-ClaudishArguments -ClaudishPath 'C:\fake\claudish.js' -Model 'gpt-test' -ClaudeArgs @($printFlag, 'prompt'))
        Assert-True ($arguments -notcontains '--interactive') 'interactive flag is absent'
        Assert-True ($arguments -notcontains '--json') 'JSON flag is absent'
        $separator = [Array]::IndexOf($arguments, '--')
        Assert-Sequence @($arguments[($separator + 1)..($arguments.Count - 1)]) @($printFlag, 'prompt') 'headless Claude arguments'
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

Test-Case 'patched real Claudish keeps key from fake Claude' {
    $testDrive = Join-Path ([System.IO.Path]::GetTempPath()) "ccx-claudish-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $testDrive | Out-Null
    $names = @('CLAUDE_PATH', 'HOME', 'USERPROFILE', 'LOCALAPPDATA')
    $saved = @{}
    try {
        $fakeClaude = Join-Path $testDrive 'claude.cmd'
        $environmentCapturePath = Join-Path $testDrive 'claude-env.txt'
        Set-Content -LiteralPath $fakeClaude -Encoding ascii -Value @'
@echo off
if defined OPENAI_API_KEY (
  >"%CCX_ENV_CAPTURE_PATH%" echo(present
) else (
  >"%CCX_ENV_CAPTURE_PATH%" echo(absent
)
exit /b 0
'@
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        $env:CLAUDE_PATH = $fakeClaude
        $env:HOME = $testDrive
        $env:USERPROFILE = $testDrive
        $env:LOCALAPPDATA = $testDrive
        $oldCapturePath = $env:CCX_ENV_CAPTURE_PATH
        $env:CCX_ENV_CAPTURE_PATH = $environmentCapturePath
        try {
            $claudishArgs = @(Get-ClaudishArguments `
                -ClaudishPath (Join-Path $root 'node_modules/claudish/dist/index.js') `
                -Model 'gpt-test' `
                -ClaudeArgs @('-p', 'smoke'))
            $output = @(Invoke-CcxCommand `
                -BunPath (Get-Command bun -CommandType Application).Source `
                -ClaudishArgs $claudishArgs `
                -OpenAIKey 'fake-openai-key')
        } finally {
            $env:CCX_ENV_CAPTURE_PATH = $oldCapturePath
        }
        Assert-Equal $script:CcxExitCode 0 'Claudish smoke exit code'
        Assert-Equal $output.Count 0 'Claudish smoke stdout'
        Assert-Equal (Get-Content -Raw -LiteralPath $environmentCapturePath).Trim() 'absent' 'Claude OpenAI key state'
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Remove-Item -LiteralPath $testDrive -Recurse -Force
    }
}

Test-Case 'dependency patch and artifact contract is minimal' {
    $package = Get-Content -Raw -LiteralPath (Join-Path $root 'package.json') | ConvertFrom-Json
    Assert-Equal $package.packageManager 'bun@1.3.14' 'Bun pin'
    Assert-Equal $package.dependencies.claudish '7.15.0' 'Claudish pin'
    Assert-Equal $package.patchedDependencies.'claudish@7.15.0' 'patches/claudish@7.15.0.patch' 'patch registration'
    $patchLines = Get-Content -LiteralPath (Join-Path $root 'patches/claudish@7.15.0.patch')
    $added = @($patchLines | Where-Object { $_ -match '^\+(?!\+\+)' })
    $removed = @($patchLines | Where-Object { $_ -match '^-(?!--)' })
    Assert-Sequence $added @('+  delete env.OPENAI_API_KEY;') 'patch additions'
    Assert-Equal $removed.Count 0 'patch removal count'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'litellm.yaml'))) 'LiteLLM config is absent'
    $launcher = Get-Content -Raw -LiteralPath $launcherPath
    Assert-True ($launcher -notmatch 'ProcessStartInfo|Stop-CcxProcessTree|Test-CcxInteractive|taskkill') 'obsolete process machinery is absent'
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($failures.Count) launcher contract test(s) failed."
}

'PASS: direct Claudish launcher contract'
