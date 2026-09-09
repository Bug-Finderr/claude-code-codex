# Claude Code with OpenAI models

`ccx` runs Claude Code through the project-local Claudish package. It uses OpenAI `gpt-6-astra` by default.

## Requirements

- PowerShell 7
- Bun 1.3.14
- Claude Code installed on `PATH`
- A ChatGPT subscription with access to the selected model, or an OpenAI API key

Install the pinned dependencies once:

```powershell
bun install --frozen-lockfile
```

For ChatGPT subscription access, sign in once through Claudish:

```powershell
bun node_modules/claudish/dist/index.js login codex
```

This is separate from `codex login`. Claudish stores and refreshes its own login in `~/.claudish/codex-oauth.json`; ccx does not copy Codex login tokens. Subscription calls use your ChatGPT plan's limits, not API credits.

The PowerShell profile command is:

```powershell
function ccx { & 'D:/Files/Dev/ccx/ccx.ps1' @args }
```

## Patched Claudish behavior

`ccx` uses Claudish 9.1.0 with these local changes:

- Keep each request's model. Ordinary Sonnet Agent calls inherit the selected OpenAI model; explicit Fable, Opus, and workflow models stay unchanged.
- Fall back to a configured API key if ChatGPT credentials cannot load or refresh. API fallback uses API billing.
- Route Astra through OpenAI Responses even without a current model catalog.
- Start workflow token counts with an estimate of the current request, not the previous turn.
- Forward mid-turn steering messages to OpenAI.
- Use the configured Anthropic key inside the proxy, without exposing either provider key to Claude Code.
- Keep the configured Windows statusline instead of Claudish's fallback.
- Detect headless output correctly and make `--models-skip-update` skip both catalog and version checks.

Upstream 9.0.7 added catalog-based Responses routing. The Astra fallback stays because ccx skips catalog downloads at launch; a missing or older catalog must not change its endpoint. None of the other local changes are replaced by 9.1.0.

## Usage

Use the default model:

```powershell
ccx
ccx -p 'Reply with exactly: CCX_OK' --output-format text
```

With a Claudish ChatGPT login, ccx tries the subscription first (`cx@`). If credentials are missing or cannot refresh, it falls back to a configured API key. Without a subscription login, an `OPENAI_API_KEY` in the environment or a legacy key in `~/.codex/auth.json` uses the API directly (`oai@`). For example, to configure an API proxy:

```powershell
$env:OPENAI_API_KEY = '<proxy-token>'
$env:OPENAI_BASE_URL = '<proxy_url>'
ccx
```

`OPENAI_BASE_URL` applies to direct API calls and API fallback. It accepts the usual OpenAI SDK form ending in `/v1`; ccx removes that suffix because Claudish appends the versioned endpoint itself. The default API base URL is `https://api.openai.com`. Subscription calls go to ChatGPT instead. Fallback accepts `OPENAI_CODEX_API_KEY` or `OPENAI_API_KEY`; it does not retry quota errors or general request failures through the paid API. If neither login nor a usable key is available, the request fails.

Set the OpenAI model explicitly with either wrapper form:

```powershell
ccx --model gpt-6-astra
ccx --model=gpt-6-astra -p 'Summarize this repository'
```

`ccx` consumes `--model` only before the first `--`. The separator itself is removed, and every later argument is passed literally to Claude Code:

```powershell
ccx --model gpt-6-astra -- --verbose
```

OpenAI model IDs use the selected subscription or API route. Native Claude requests prefer `ANTHROPIC_API_KEY` and otherwise use the existing Claude Code subscription login. The task UI and transcript therefore report the model that actually handled each task.

PowerShell invokes Bun directly, so stdout remains naturally capturable, incremental, and pipeable; stderr and Ctrl+C retain native behavior. The child exit code becomes the script exit code rather than output.

Every invocation disables Claudish auto approval and passes Claude Code's `--dangerously-skip-permissions` flag before the passthrough separator. It temporarily sets the selected provider variables and restores the parent environment afterward.

`ccx` invokes the pinned local Claudish entry point directly with Bun. It does not start or manage a separate local gateway daemon.

Claudish stores session files under `~/.claudish`.
