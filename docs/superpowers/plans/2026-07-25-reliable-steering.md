# Reliable ccx Steering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ccx honor user corrections typed during an active Claude Code turn.

**Architecture:** Keep Claude Code's queue and ccx's launcher unchanged. Patch Claudish's OpenAI message formatter so complete Claude-specific `<system-reminder>` text blocks are emitted before genuine user text from the same user message, leaving tool results first and user steering last.

**Tech Stack:** PowerShell 7, Bun 1.3.14, Claudish 7.17.1, bundled JavaScript patch

---

### Task 1: Pin the steering-order contract

**Files:**
- Modify: `tests/ccx.Tests.ps1`

- [ ] **Step 1: Add the focused failing check**

```powershell
Test-Case 'Claudish presents queued steering after synthetic reminders' {
    $source = Get-Content -LiteralPath (Join-Path $root 'node_modules/claudish/dist/index.js') -Raw
    Assert-True ($source.Contains('contentParts.unshift(...systemReminderParts);')) 'system reminders precede genuine user text'
}
```

- [ ] **Step 2: Verify the contract is initially red**

Run: `pwsh -NoProfile -File tests/ccx.Tests.ps1`

Expected: only `Claudish presents queued steering after synthetic reminders` fails because the current bundle has no ordering correction.

### Task 2: Update and patch Claudish

**Files:**
- Modify: `package.json`
- Modify: `bun.lock`
- Delete: `patches/claudish@7.15.0.patch`
- Create: `patches/claudish@7.17.1.patch`
- Modify: `README.md`

- [ ] **Step 1: Update the pinned dependency**

Change `claudish` from `7.15.0` to `7.17.1`, temporarily remove the obsolete `patchedDependencies` entry, then run `bun install` so `bun.lock` resolves the matching package and platform binaries. Run `bun patch claudish@7.17.1` before editing the installed bundle.

- [ ] **Step 2: Port the existing local patch**

Apply every existing ccx-specific hunk from `patches/claudish@7.15.0.patch` to `node_modules/claudish/dist/index.js`. Preserve its invocation-mode, environment isolation, model routing, statusline, workflow usage, and update-check behavior.

- [ ] **Step 3: Add the minimal ordering correction**

Within `processUserMessage`, collect complete synthetic reminder blocks separately and prepend them to genuine content before the formatter emits the user message:

```javascript
const systemReminderParts = [];

// In the text-block branch:
const part = { type: "text", text: block.text };
if (
  block.text.trim().startsWith("<system-reminder>") &&
  block.text.trim().endsWith("</system-reminder>")
) {
  systemReminderParts.push(part);
} else {
  contentParts.push(part);
}

// After processing blocks, before emitting contentParts:
contentParts.unshift(...systemReminderParts);
```

Tool results remain emitted before the combined text content. No launcher, hook, terminal, or queue logic changes.

- [ ] **Step 4: Generate the new Bun patch**

Run `bun patch --commit claudish@7.17.1`, retain the generated `patches/claudish@7.17.1.patch`, remove the 7.15.0 patch, and run `bun install` once more to verify a clean patch application.

- [ ] **Step 5: Correct the version-specific README statement**

Replace the version-specific residue sentence with: `Claudish stores session files under ~/.claudish.` Do not add steering instructions because steering should work normally.

- [ ] **Step 6: Run the repository contract suite**

Run: `pwsh -NoProfile -File tests/ccx.Tests.ps1`

Expected: every test passes, including the new ordering contract.

- [ ] **Step 7: Commit the implementation**

```powershell
git add package.json bun.lock patches README.md tests/ccx.Tests.ps1
git commit -m "fix: preserve mid-turn user steering"
```

### Task 3: Verify actual steering

**Files:**
- No repository changes

- [ ] **Step 1: Reinstall from the committed lock and patch**

Run: `bun install --frozen-lockfile`

Expected: Claudish 7.17.1 installs and the local patch applies without warnings.

- [ ] **Step 2: Repeat the controlled interactive case**

Start ccx with a prompt that reads `package.json`, waits 20 seconds, and summarizes dependencies. During the wait, enter: `Change of plan: do not summarize dependencies. Tell me only the packageManager value.`

Expected: the final answer contains only `bun@1.3.14` rather than the original dependency summary.

- [ ] **Step 3: Check the complete diff**

Run: `git diff main...HEAD --check` and `git status --short`

Expected: no whitespace errors and a clean working tree.
