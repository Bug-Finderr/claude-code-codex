# Claude Code with OpenAI models

`ccx` runs Claude Code through the project-local Claudish package. It uses OpenAI `gpt-5.6-sol` by default.

## Requirements

- PowerShell 7
- Bun 1.3.14
- Claude Code installed on `PATH`
- `OPENAI_API_KEY` in `~/.codex/auth.json`
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

Select another OpenAI model with either wrapper form:

```powershell
ccx --model gpt-5.6-sol
ccx --model=gpt-5.6-sol -p 'Summarize this repository'
```

`ccx` consumes `--model` only before the first `--`. The separator itself is removed, and every later argument is passed literally to Claude Code:

```powershell
ccx --model gpt-5.6-sol -- --verbose
```

`ccx` preserves Claude Code's normal mode selection. With attached output it is interactive unless `-p` or `--print` is present; redirected output is noninteractive. Interactive runs suppress Claudish's package update check without forcing Claude JSON output.

Every invocation explicitly disables Claudish auto approval and passes Claude Code's `--dangerously-skip-permissions` flag directly before the passthrough separator. It also disables Claudish usage stats, telemetry, logs, and diagnostics and skips model-catalog updates. The OpenAI key and official base URL are set on the Claudish translator child; the key is removed before Claude Code is spawned. Inherited Anthropic credentials are removed from Claudish without changing the parent PowerShell environment.

`ccx` invokes the pinned local Claudish entry point directly with Bun. It does not start or manage a separate local gateway daemon. If PowerShell interrupts the invocation, the exact Claudish child process tree is terminated.

Claudish still creates session files under `~/.claudish`; version 7.15.0 may leave Windows `status-*.js` files behind.
