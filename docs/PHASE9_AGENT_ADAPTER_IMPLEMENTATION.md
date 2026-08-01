# Phase 9 Agent Adapter Foundation

## Bug theory

A generic agent entry can advertise an action without proving that its transport
has semantic state, that it declared the capability, or that the target task,
worktree, and process still belong together. A PTY parser can then be mistaken
for destructive authority, or PID reuse can redirect a valid action.

## Red-first contract

- Unsupported semantic capability is denied.
- PTY heuristic transport exposes observe only and never destructive authority.
- Task ownership mismatch is denied.
- Canonical worktree mismatch is denied.
- PID plus process-start identity mismatch is denied.
- Semantic ACP exposes only its declared capabilities.

Tests first failed because `GuardianAgentAdapter` types did not exist. The pure
policy implementation now makes all six tests green.

## Implemented

- Typed agent capabilities and semantic-versus-PTY transport identity.
- Effective capability intersection for observe-only PTY fallback.
- Task/worktree/PID+start-identity ownership fence.
- Fail-closed policy decision with explicit denial reasons.

## Evidence boundary

This is the capability and ownership foundation. It does not claim a live ACP
handshake, a production ACP adapter, AHP compatibility, terminal truth, or
destructive authority. Those remain disabled until a semantic adapter proves its
declared capabilities and resource ownership end to end.
