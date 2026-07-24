# Reliable ccx Steering

## Problem

Claude Code receives corrections typed during a turn, but Claudish translates a later Claude-specific `<system-reminder>` as the newest OpenAI user message. Native Claude understands that wrapper; `gpt-5.6-sol` can instead continue the superseded task.

## Design

- Update Claudish from 7.15.0 to the current 7.17.1.
- In the OpenAI message formatter, place synthetic reminder-only user content before the genuine queued user correction, while preserving tool-result order.
- Keep Claude Code's terminal input, queue, hooks, and ccx launcher unchanged.

## Verification

- Add one focused test for the patched ordering only.
- Run the existing ccx checks.
- Repeat the controlled terminal case: while dependency analysis is running, redirect it to return only `packageManager`. ccx must honor the correction, matching native Claude Code.
