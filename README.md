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

An existing file-based Codex ChatGPT login works automatically (`CODEX_HOME/auth.json`, or `~/.codex/auth.json`). ccx rereads it for each request without copying or changing tokens. Codex owns refresh; open Codex if that login expires. API-key fallback still applies.

Alternatively, sign in through Claudish:

```powershell
bun node_modules/claudish/dist/index.js login codex
```

Claudish stores and refreshes that separate login in `~/.claudish/codex-oauth.json` and prefers it when present. Subscription calls use your ChatGPT plan's limits, not API credits.

The PowerShell profile command is:

```powershell
function ccx { & 'D:/Files/Dev/ccx/ccx.ps1' @args }
```

## Patched Claudish behavior

`ccx` uses Claudish 9.3.0 with these local changes:

- Keep each request's model. Ordinary Sonnet Agent calls inherit the selected OpenAI model; explicit Fable, Opus, and workflow models stay unchanged.
- Fall back to a configured API key if ChatGPT credentials cannot load or refresh. API fallback uses API billing.
- Reuse an existing file-based Codex ChatGPT login without a second sign-in or token copies.
- Route Astra through OpenAI Responses even without a current model catalog.
- Preserve Astra's requested `xhigh` and `max` effort on the ChatGPT route instead of reducing it to `high`.
- Start workflow token counts with an estimate of the current request, not the previous turn.
- Forward mid-turn steering messages to OpenAI.
- Use the configured Anthropic key inside the proxy, without exposing either provider key to Claude Code.
- Keep the configured Windows statusline instead of Claudish's fallback.
- Allow Claude Code to load your claude.ai connectors using its existing login.
- Keep optional tool arguments optional in Responses, so models need not invent pagination tokens or other missing values.
- Detect headless output correctly and make `--models-skip-update` skip both catalog and version checks.

Upstream 9.2-9.3 improves interrupted streams, advisor calls, and inherited placeholder credentials. Those fixes stay unchanged. They do not replace the local behaviors above. The Astra routing fallback stays because ccx skips catalog downloads at launch.

The launcher reads Codex auth only once. The patch also shares identical steering handling, selects the Windows statusline once, and uses one native-auth decision chain.

## Claude.ai connectors

Sign in to Claude Code with the same Claude account you use on the web, then open `/mcp` inside ccx. Claudish no longer forces `disableClaudeAiConnectors: true`. Your own connector-disable settings and organization policies still apply.

Claude Code 2.1.270 fetches discovery and connects through Anthropic's own endpoints, not the local model proxy. No extra proxy route or dummy Anthropic token is needed. Model calls can still use ChatGPT while connectors use your Claude login. A connector marked "needs authentication" must be signed in separately; enabling discovery does not grant it access.

See [Claude Code's connector documentation](https://code.claude.com/docs/en/mcp).

## Usage

Use the default model:

```powershell
ccx
ccx -p 'Reply with exactly: CCX_OK' --output-format text
```

With a Codex or Claudish ChatGPT login, ccx tries the subscription first (`cx@`). If credentials are missing, expired, or cannot refresh, it falls back to a configured API key. Without a subscription login, an `OPENAI_API_KEY` in the environment or a legacy key in Codex's auth file uses the API directly (`oai@`). For example, to configure an API proxy:

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
