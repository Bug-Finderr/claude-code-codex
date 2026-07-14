# Claude Code with GPT-5.6 Sol

`ccx` is a personal PowerShell abbreviation for running Claude Code with OpenAI `gpt-5.6-sol` through a temporary local LiteLLM gateway.

## Requirements

- PowerShell 7
- `claude` on `PATH`
- `uvx` on `PATH`
- `OPENAI_API_KEY` in `~/.codex/auth.json`
- API access to `gpt-5.6-sol`

The PowerShell profile command is:

```powershell
function ccx { & 'D:/Files/Dev/ccx/ccx.ps1' @args }
```

Open a new PowerShell session after adding or changing the profile.

## Usage

Interactive:

```powershell
ccx
```

Headless:

```powershell
ccx -p 'Reply with exactly: CCX_OK' --output-format text
```

All normal Claude Code arguments are forwarded.

## How it works

`ccx` reads the existing OpenAI key from Codex auth, starts LiteLLM on a temporary loopback port, points Claude Code at that gateway, and selects `gpt-5.6-sol`. Environment changes apply only to the invocation and are restored afterward. The gateway is stopped when Claude exits.

LiteLLM output is written to `logs/`, which Git ignores. The OpenAI key and temporary gateway token are not written to configuration or logs.
