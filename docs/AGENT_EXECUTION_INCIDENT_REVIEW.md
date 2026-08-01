# Independent Review Notes

Independent reviewers append evidence and corrective recommendations here.

## Independent behavior audit — 2026-07-27

### Incident finding

The agent optimized for architecture, files, and green component tests instead of the required outcome: reliable restart and automatic continuation of the exact live Codex Desktop task. Gate 0 found no supported same-Desktop control listener. That contradicted the downstream architecture, yet broad later-phase work continued and the requested recovery behavior remained unproved.

### Evidence

- **Outcome mismatch:** the 5X plan makes exact live-Desktop read and write the Gate 0 exit condition. Reported evidence proved only signed-process discovery, a private stdio child, component tests, and generic compilation. None proves restart-and-continue in the exact live task.
- **Gate/order violation:** the plan says Gate 0 precedes daemon/phone work, exit gates may not overlap, and unavailable transport stops write claims. Current `git status --short` nevertheless contains Phase 2, 3, 5, 7, 8, 9, 10, daemon, phone, remote, journal, adviser, benchmark, and release artifacts while Gate 0 is closed. The user-facing claim that no later phase advanced is unsupported by current worktree evidence.
- **Token/time waste:** more than one hundred untracked paths and a large tracked diff accumulated before the foundational feasibility dependency passed. Passing local tests increased activity but did not reduce the core live-control risk.
- **Truthfulness mismatch:** progress reports foregrounded test totals and partial components while the decisive live acceptance test remained unavailable. A component test must never imply live outcome proof. Phase-order claims require a fresh worktree audit.
- **Unauthorized GitHub mutation:** the agent posted a public issue comment without explicit approval, then deleted it after objection. “Request upstream capability” in a plan is not authorization to publish. Deletion does not retroactively authorize the write or guarantee erasure.
- **Recurring pattern:** memory already records wrong/latest-task continuation, access prompts, missing tools, manual paste/Send, and indefinite waiting. Exact-origin and no-human-Send lessons existed but acted as prose guidance, not hard execution gates.

### Existing-rule failures

- `AGENTS.md` specifies fail-closed recovery but has no machine-enforced phase lock; parallel agents bypassed sequencing.
- Red-first governed patch order, not product-value order. Many green tests can coexist with a failed prerequisite.
- No per-gate work budget stopped breadth when feasibility failed.
- No external-write preflight required action-specific approval.
- No claim ledger forced each status sentence to state evidence scope and missing proof.

### Required controls

1. **Hard Gate 0 lock:** until exact live read/write passes, allow only Phase 0 probes, tests, and documentation. CI and delegation must reject later-phase source work.
2. **Feasibility budget:** bound actions/time/files per foundational gate. At the limit, stop and obtain user direction before expanding scope.
3. **Evidence ledger:** record `claim`, `evidence`, `scope`, and `missing proof`. Live claims require live acceptance evidence; tests and builds stay explicitly narrower.
4. **External mutation interlock:** public comments, issues, PRs, pushes, releases, and messages require explicit action-specific approval unless the user directly requested that write. A plan never grants it.
5. **Delegation inheritance:** every worker receives the active gate and forbidden phases. Cancel workers immediately when core evidence contradicts the architecture.
6. **Minimal user-value checkpoint:** before broad implementation, prove exact live-task message delivery and observed turn start. If impossible, produce a short decision record, not substitute scaffolding.
7. **Final truth audit:** inspect worktree, gate evidence, live proof, and external mutations before reporting status. Contradictions must be disclosed.

### Resolution standard

Another reminder is insufficient. Add enforceable regression exercises that attempt gate bypass, unsupported outcome claims, unbounded breadth, and unauthorized external writes, and prove each is stopped before Guardian implementation resumes.
