# Documentation map

This folder contains both current operating documentation and dated engineering evidence. Read the current guides first.

## Current guides

| Document | Audience | Purpose |
| --- | --- | --- |
| [Project README](../README.md) | Everyone | Plain-language overview, install, limits |
| [User guide](USER_GUIDE.md) | Mac users | Daily use and menu/dashboard meanings |
| [Recovery workflows](RECOVERY_WORKFLOWS.md) | Users and agent authors | Exact three-way recovery contract and capability status |
| [Troubleshooting](TROUBLESHOOTING.md) | Users and operators | Safe symptom-to-action guide |
| [Technical setup](../TECHNICAL_SETUP.md) | Developers and operators | Build, install, MCP, health, update, uninstall |
| [Security](../SECURITY.md) | Users and security reviewers | Reporting, privacy, trust boundaries |
| [Privacy](PRIVACY.md) | Users | Stored data, retention, deletion, diagnostics |
| [Development](DEVELOPMENT.md) | Contributors | Architecture and test lanes |
| [Upgrading](UPGRADING.md) | Operators | Safe update and rollback |
| [Release checklist](RELEASE.md) | Maintainers | Public source and binary release gates |
| [Remote and phone status](REMOTE_ACCESS.md) | Developers | Experimental, default-off boundary |

## Current design and security evidence

- [5X plan](CODEX_GUARDIAN_5X_PLAN.md) — original target architecture plus current-status note.
- [Recovery reliability audit](RECOVERY_RELIABILITY_AUDIT.md) — adopted recovery invariants and sources.
- [Security threat model](SECURITY_THREAT_MODEL.md) — detailed attacker model and remaining gaps.
- [Upstream Desktop control request](UPSTREAM_CODEX_DESKTOP_CONTROL_REQUEST.md) — missing Codex capability that blocks authoritative automatic restart.
- [GuardianBench](../Benchmarks/GuardianBench/README.md) — deterministic policy benchmark rules.

## Historical engineering records

Files beginning with `PHASE`, `GATE`, or `AGENT_EXECUTION`, plus incident reports and comparison research, are point-in-time implementation records. They explain why decisions were made. They are not the current user contract and may contain stale plans, line numbers, or “not implemented” statements.

When a historical record conflicts with the current guides or current source, the current source and current guides win. Do not rewrite old evidence to make history look cleaner; add a dated correction or superseding link instead.

## Claim labels

Use these labels consistently:

- **Implemented** — source exists and relevant tests pass.
- **Installed** — the current local production bundle contains it.
- **Live-proven** — the real user-visible flow was observed end to end.
- **Experimental** — source exists, but production reliability or UX is not proven.
- **Unavailable** — the UI/API must refuse or fail closed.
- **Planned** — design only.

Never use unit tests, a successful build, process existence, or a copied prompt as proof of live recovery.
