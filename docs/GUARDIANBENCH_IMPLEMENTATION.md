# GuardianBench executable baseline

## Bug theory

GuardianBench was prose only. Nothing rejected a malformed or changed scenario fixture. Nothing produced deterministic, machine-readable comparison evidence. A person could accidentally report unsupported behavior as failure or publish measurements without confidence metadata.

## Regression-first proof

The first test imported the absent `GuardianBench` module and required fixture validation, deterministic byte-identical output, Wilson 95% metadata, and `not_available` semantics. RED was captured as `error: no such module 'GuardianBench'`.

## Implemented

- Frozen versioned scenarios with strict semantic validation: schema v1, nonempty revision, unique IDs, positive trials.
- Seeded deterministic Guardian policy runner. Same suite, seed, and metadata produce identical JSON bytes.
- Versioned result JSON Schema.
- Wilson 95% interval metadata. Zero observed failures carries an explicit nonzero-risk warning.
- Unsupported scenarios emit `status: not_available`; measurements and confidence bounds remain absent.
- No network calls. No source tree scanning. No private data collection.

## Evidence boundary

This is a runner/schema baseline, not a Guardian performance claim. `mode` is always `deterministic_guardian_policy`. It executes stale-evidence fail-closed and wrong-thread rejection through GuardianCore. Unknown supported scenarios fail. Unmeasured latency stays absent. Live recovery, TLS, LAN/VPN, and comparative project measurements remain separate future evidence.

## Verification

```sh
swift build --target GuardianBenchCLI
.build/debug/guardian-bench --seed 42 > /tmp/a.json
.build/debug/guardian-bench --seed 42 > /tmp/b.json
cmp /tmp/a.json /tmp/b.json
swift test --filter GuardianBench
```
