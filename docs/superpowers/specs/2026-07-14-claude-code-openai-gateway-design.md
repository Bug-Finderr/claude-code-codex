# Claude Code OpenAI Gateway Design

## Goal

Provide an isolated `ccx` command that runs Claude Code against the OpenAI model `gpt-5.6-sol` without changing normal Claude Code authentication or storing another copy of the OpenAI API key.

## Files

- `D:/Files/Dev/ccx/ccx.ps1` launches the gateway and Claude Code.
- `D:/Files/Dev/ccx/litellm.yaml` maps the Claude-facing model name to `openai/gpt-5.6-sol`.
- `D:/Files/Dev/configs/windows/powershell/Microsoft.PowerShell_profile.ps1` receives only a small `ccx` forwarding function.

## Runtime Flow

1. Validate that `claude`, `uvx`, the LiteLLM configuration, and `~/.codex/auth.json` exist.
2. Read `OPENAI_API_KEY` from the Codex auth file in memory.
3. Reserve an ephemeral localhost port and generate an ephemeral gateway bearer token.
4. Start a pinned, non-compromised LiteLLM release through `uvx`. Give the proxy process the OpenAI key and gateway token through its child-process environment only.
5. Wait for the local gateway health endpoint with a bounded timeout. If startup fails, print a useful error and the gateway log location.
6. Temporarily set Claude Code's gateway URL, bearer token, and model variables in the launcher process, then run `claude --dangerously-skip-permissions` with all user arguments forwarded.
7. Restore any pre-existing environment values and stop the gateway process tree when Claude exits or the launcher is interrupted.

## Security and Isolation

- Never print or persist `OPENAI_API_KEY`.
- Bind the gateway only to `127.0.0.1`.
- Authenticate the local gateway with a fresh random token for each run.
- Do not modify `~/.claude/settings.json` or persistent user environment variables.
- Keep gateway logs under `D:/Files/Dev/ccx/logs/` and avoid debug-level request logging.

## Error Handling

The launcher fails before starting Claude when a prerequisite, auth property, port binding, proxy startup, or health check fails. Cleanup runs from a `finally` block so the gateway does not remain running after the session.

## Verification

1. Syntax-parse the PowerShell launcher and profile.
2. Exercise missing and fake credential paths without contacting OpenAI.
3. Start the real gateway and verify its health endpoint.
4. Run a minimal non-interactive Claude Code prompt and confirm the response is served by `gpt-5.6-sol`.
5. Confirm the proxy exits and no key was written into the created files or logs.
