# Reliable ccx Steering

## Problem

Claude Code sends corrections typed during a turn as mid-conversation system messages. Claudish's OpenAI formatter ignores system roles inside the message history, so `gpt-5.6-sol` continues the superseded task.

## Design

- Update Claudish from 7.15.0 to the current 7.17.1.
- In the OpenAI message formatter, preserve mid-conversation system messages as user input so the queued correction reaches the model after the active tool result.
- Keep Claude Code's terminal input, queue, hooks, and ccx launcher unchanged.

## Verification

- Add one focused test for the patched role handling only.
- Run the existing ccx checks.
- Repeat the controlled terminal case: while dependency analysis is running, redirect it to return only `packageManager`. ccx must honor the correction, matching native Claude Code.
