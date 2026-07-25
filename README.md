# Codex Guardian

Codex Guardian is a small shield for Codex on your Mac.

Sometimes an AI task freezes. Normally, you must reopen Codex, find the task, and explain what happened again. Guardian helps Codex restart itself and continue the same task.

## What it does

1. Codex notices that it is stuck.
2. Codex asks Guardian for help.
3. Guardian safely restarts Codex.
4. Your Mac's private built-in AI reads a small, cleaned-up summary of what happened.
5. Guardian reopens the correct desktop task and copies a useful “continue from here” message.

It can also queue several stuck tasks, so one task does not replace another.

## Install

Download this project, open Terminal in its folder, and run:

```bash
./script/install_production.sh
```

Then restart Codex once. A shield appears in your Mac menu bar when Guardian is running.

If you are a developer or need help connecting Guardian, see [Technical Setup](TECHNICAL_SETUP.md).

The included [Codex instructions](AGENTS.md) tell Codex to call Guardian itself when recovery is genuinely needed. Guardian restarts Codex and reopens the exact task without launching a second hidden Codex worker.

## Is it safe?

Guardian only restarts Codex when it can prove which task asked for help. If it cannot prove that, it stops instead.

On supported Macs, the smart recovery message is created locally with Apple Intelligence. Guardian removes common secret patterns first and never sends this summary to an online AI service. If the local model is unavailable, Guardian uses a simple safe message instead.

The project contains no API keys or accounts. Keep your own secrets out of bug reports and contributions.

## Can I sell it?

No. You may read, use, change, and share this project for noncommercial purposes. Selling it, bundling it into a paid product, or using it for paid services requires separate written permission. See [LICENSE](LICENSE).

This is public source under the PolyForm Noncommercial License 1.0.0. It is source-available, not OSI-approved open source.

## Status

This is version 1. Expect rough edges. Please open a GitHub issue for bugs, but never include passwords, tokens, private prompts, or personal files.
