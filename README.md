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

## Patched Claudish behavior

The pinned patch is limited to:

- Preserve each request's model, while ordinary Sonnet Agent calls inherit the selected OpenAI model and explicit Fable, Opus, and workflow models stay unchanged.
- Seed workflow token rows from the current request instead of the previous turn.
- Forward mid-turn steering messages to OpenAI.
- Prefer the configured native Anthropic API key in the local proxy, then remove both provider keys before spawning Claude Code.
- Keep the configured Windows statusline instead of replacing it with Claudish's fallback.
- Classify interactive versus headless mode from the actual stdout handle and suppress package checks with `--models-skip-update`.

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

OpenAI model IDs use the configured OpenAI endpoint. Native Claude IDs prefer `ANTHROPIC_API_KEY` and otherwise use the existing Claude Code subscription login. The task UI and transcript therefore report the model that actually handled each task.

PowerShell invokes Bun directly, so stdout remains naturally capturable, incremental, and pipeable; stderr and Ctrl+C retain native behavior. The child exit code becomes the script exit code rather than output.

Every invocation disables Claudish auto approval and passes Claude Code's `--dangerously-skip-permissions` flag before the passthrough separator. It temporarily sets the selected provider variables and restores the parent environment afterward.

`ccx` invokes the pinned local Claudish entry point directly with Bun. It does not start or manage a separate local gateway daemon.

Claudish stores session files under `~/.claudish`.
