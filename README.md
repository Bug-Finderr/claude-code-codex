# Claude Code with OpenAI models

`ccx` runs Claude Code through the project-local Claudish package. It uses OpenAI `gpt-5.6-sol` by default.

## Requirements

- PowerShell 7
- Bun 1.3.14
- Claude Code installed on `PATH`
- `OPENAI_API_KEY` in the environment or `~/.codex/auth.json`
- API access to the selected OpenAI model

Install the pinned dependencies once:

```powershell
bun install --frozen-lockfile
```

The PowerShell profile command is:

```powershell
function ccx { & 'D:/Files/Dev/ccx/ccx.ps1' @args }
```

## Usage

Use the default model:

```powershell
ccx
ccx -p 'Reply with exactly: CCX_OK' --output-format text
```

Environment variables take precedence over the defaults. For example, to use the API proxy:

```powershell
$env:OPENAI_API_KEY = '<proxy-token>'
$env:OPENAI_BASE_URL = '<proxy_url>'
ccx
```

`OPENAI_BASE_URL` accepts the usual OpenAI SDK form ending in `/v1`; `ccx` removes that suffix because Claudish appends the versioned endpoint itself. Without the variables, the key falls back to `~/.codex/auth.json` and the base URL to `https://api.openai.com`.

Select another OpenAI model with either wrapper form:

```powershell
ccx --model gpt-5.6-terra
ccx --model=gpt-5.6-luna -p 'Summarize this repository'
```

`ccx` consumes `--model` only before the first `--`. The separator itself is removed, and every later argument is passed literally to Claude Code:

```powershell
ccx --model gpt-5.6-sol -- --verbose
```

The pinned Claudish patch classifies mode from its actual stdout handle. Attached positional prompts, flags, and resume flows stay interactive; redirected output and explicit `-p` or `--print` stay headless. `--models-skip-update` also suppresses Claudish's package update check.

PowerShell invokes Bun directly, so stdout remains naturally capturable, incremental, and pipeable; stderr and Ctrl+C retain native behavior. The child exit code becomes the script exit code rather than output.

Every invocation explicitly disables Claudish auto approval and passes Claude Code's `--dangerously-skip-permissions` flag directly before the passthrough separator. It temporarily sets the selected OpenAI key and base URL plus Claudish isolation variables, removes inherited Anthropic credentials, and restores the parent environment afterward. The dependency patch removes the OpenAI key before Claude Code is spawned, after Claudish has read it for its local translator.

`ccx` invokes the pinned local Claudish entry point directly with Bun. It does not start or manage a separate local gateway daemon.

Claudish still creates session files under `~/.claudish`; version 7.15.0 may leave Windows `status-*.js` files behind.
