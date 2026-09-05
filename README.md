# Claude Code with OpenAI models

`ccx` runs Claude Code through the project-local Claudish package. It uses OpenAI `gpt-6-astra` by default.

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

## Patched Claudish behavior

`ccx` patches upstream Claudish only to:

- Route Astra through OpenAI Responses and keep each request's model. Ordinary Sonnet Agent calls inherit the selected OpenAI model; explicit Fable, Opus, and workflow models stay unchanged.
- Start workflow token counts from the current request, not the previous turn.
- Forward mid-turn steering messages to OpenAI.
- Use the configured Anthropic key inside the proxy, without exposing either provider key to Claude Code.
- Keep the configured Windows statusline instead of Claudish's fallback.
- Detect headless output correctly and make `--models-skip-update` skip both catalog and version checks.

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

Set the OpenAI model explicitly with either wrapper form:

```powershell
ccx --model gpt-6-astra
ccx --model=gpt-6-astra -p 'Summarize this repository'
```

`ccx` consumes `--model` only before the first `--`. The separator itself is removed, and every later argument is passed literally to Claude Code:

```powershell
ccx --model gpt-6-astra -- --verbose
```

OpenAI model IDs use the configured OpenAI endpoint. Native Claude IDs prefer `ANTHROPIC_API_KEY` and otherwise use the existing Claude Code subscription login. The task UI and transcript therefore report the model that actually handled each task.

PowerShell invokes Bun directly, so stdout remains naturally capturable, incremental, and pipeable; stderr and Ctrl+C retain native behavior. The child exit code becomes the script exit code rather than output.

Every invocation disables Claudish auto approval and passes Claude Code's `--dangerously-skip-permissions` flag before the passthrough separator. It temporarily sets the selected provider variables and restores the parent environment afterward.

`ccx` invokes the pinned local Claudish entry point directly with Bun. It does not start or manage a separate local gateway daemon.

Claudish stores session files under `~/.claudish`.
