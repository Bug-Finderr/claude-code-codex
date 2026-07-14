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
