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

'PASS: gateway configuration'
