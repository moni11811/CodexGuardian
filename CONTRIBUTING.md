# Contributing

Contributions are welcome for permitted noncommercial purposes under the project license.

## Before changing code

1. Describe the user-visible outcome.
2. State the bug theory or design invariant.
3. Add a regression that fails for the observed symptom.
4. Make the smallest coherent change.
5. Run the relevant source, packaging, and live-proof lanes.

Do not repeat deterministic failures unchanged. Do not weaken a fail-closed safety check to make a test or demo pass.

## Pull requests

Include:

- problem and user impact
- theory and changed invariant
- failing-before/passing-after test
- exact commands run
- proof boundary and known limitations
- security/privacy effects
- migration and rollback effects

Keep generated builds, Guardian state, logs, personal paths, and credentials out of commits.

## Required checks

At minimum:

```bash
swift test
./script/test_mcp.sh
./script/check_public_repo.sh
git diff --check
```

Run packaging, production install, phone, recovery, benchmark, or security lanes when your change touches them. See [Development and testing](docs/DEVELOPMENT.md).

## Public evidence

Use synthetic fixtures. Never attach raw Codex rollouts, prompts, Guardian databases, WAL files, credentials, `remote.json`, pairing codes, private keys, or full environment/launchd dumps.

## Licensing

By contributing, you represent that you have the right to submit the contribution and agree that it is distributed under the repository’s [PolyForm Noncommercial License 1.0.0](LICENSE). Do not add dependencies or assets with incompatible terms.
