# Codex Guardian

Codex Guardian is a small shield for Codex on your Mac.

Sometimes an AI task gets stuck. Guardian helps it find the same task and try again without losing its place.

## What it does

When Codex can still respond, Guardian finds the exact task. Codex then uses its own built-in desktop command to send a “continue” message to that task. This is the normal recovery path. It does not restart the app.

If Codex itself must restart, Guardian first gives the exact task a small automatic “are we back?” reminder. Guardian refuses to restart unless that reminder is safely ready. It ignores only that reminder while waiting; real work in the same task still counts as busy. It waits for every other task and for 15 quiet seconds. After Codex and its helper finish reopening, the reminder continues the correct task automatically, then removes itself. No copy, paste, or Send step.

If Guardian cannot tell whether a task is finished, it waits. The shield menu has a clearly named force-restart button for emergencies.

Guardian can queue several restart requests. One stuck task does not replace another.

## Install

Download this project, open Terminal in its folder, and run:

```bash
./script/install_production.sh
```

Then restart Codex once. A shield appears in your Mac menu bar when Guardian is running.

If you are a developer or need help connecting Guardian, see [Technical Setup](TECHNICAL_SETUP.md).

The included [Codex instructions](AGENTS.md) teach Codex to use same-task recovery first. Guardian never launches a second hidden Codex worker.

## Is it safe?

Guardian acts only when it can prove which task asked for help. If it cannot prove that, it stops.

On supported Macs, restart recovery messages are created locally with Apple Intelligence. Guardian removes common secret patterns first and never sends this summary to an online AI service. If the local model is unavailable, Guardian uses a simple safe message instead.

The project contains no API keys or accounts. Keep your own secrets out of bug reports and contributions.

## Can I sell it?

No. You may read, use, change, and share this project for noncommercial purposes. Selling it, bundling it into a paid product, or using it for paid services requires separate written permission. See [LICENSE](LICENSE).

This is public source under the PolyForm Noncommercial License 1.0.0. It is source-available, not OSI-approved open source.

## Status

This is version 1. Expect rough edges. Please open a GitHub issue for bugs, but never include passwords, tokens, private prompts, or personal files.
