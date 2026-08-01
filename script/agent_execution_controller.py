#!/usr/bin/env python3
"""Fail-closed, stateful execution guard for Codex agent work."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import tempfile
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
DEFAULT_MAX_NO_PROGRESS_ROUNDS = 3
DEFAULT_MAX_FALLBACKS = 1
DEFAULT_MAX_TOKENS = 250_000
DEFAULT_MAX_ELAPSED_SECONDS = 3_600
EVIDENCE_RANK = {
    "static": 0,
    "build": 1,
    "component": 2,
    "integration": 3,
    "live": 4,
}
RELEASE_CLASSES = {"install", "push", "deploy", "release", "restart"}
PAYLOAD_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


class PolicyDenied(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PolicyDenied(message)


def require_text(value: str, label: str) -> str:
    require(bool(value and value.strip()), f"{label} missing")
    require(value == value.strip(), f"{label} must be canonical")
    require(not any(ord(char) < 32 for char in value), f"{label} contains control characters")
    return value


def now_epoch() -> int:
    return int(time.time())


@contextmanager
def locked_state(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = Path(f"{path}.lock")
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        with os.fdopen(descriptor, "r+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            yield
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    finally:
        try:
            os.chmod(lock_path, 0o600)
        except FileNotFoundError:
            pass


def load_state(path: Path) -> dict[str, Any]:
    require(path.is_file(), f"execution state missing: {path}")
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PolicyDenied(f"execution state unreadable: {error}") from error
    require(isinstance(state, dict), "execution state must be an object")
    require(state.get("schema_version") == SCHEMA_VERSION, "unsupported execution state schema")
    required = {
        "outcome",
        "gates",
        "evidence",
        "limits",
        "loss_circuit",
        "workers",
        "routes",
        "failures",
        "authorizations",
        "writes",
        "waits",
        "current_turn",
    }
    require(required.issubset(state), "execution state is incomplete")
    return state


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary:
            json.dump(state, temporary, indent=2, sort_keys=True)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
        os.chmod(path, 0o600)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def new_state(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "execution_id": str(uuid.uuid4()),
        "created_at": now_epoch(),
        "current_turn": require_text(args.turn, "current turn"),
        "outcome": {
            "description": require_text(args.outcome, "user-visible outcome"),
            "direct_proof": require_text(args.direct_proof, "direct proof"),
        },
        "gates": {
            require_text(args.gate, "mandatory gate"): {
                "mandatory": True,
                "state": "open",
                "required_evidence": args.required_evidence,
                "evidence": [],
                "symptom": None,
                "evidence_boundary": None,
            }
        },
        "active_gate": args.gate,
        "evidence": {},
        "limits": {
            "max_no_progress_rounds": args.max_no_progress_rounds,
            "max_fallbacks": args.max_fallbacks,
            "max_tokens": args.max_tokens,
            "max_elapsed_seconds": args.max_elapsed_seconds,
            "tokens_total": 0,
            "elapsed_seconds": 0,
            "no_progress_rounds": 0,
        },
        "loss_circuit": {"open": False, "reasons": []},
        "progress": [],
        "workers": {},
        "routes": {},
        "failures": {},
        "authorizations": [],
        "writes": [],
        "artifacts": [],
        "waits": {},
    }


def validate_init_limits(args: argparse.Namespace) -> None:
    require(args.max_no_progress_rounds >= 1, "no-progress limit must be positive")
    require(args.max_fallbacks >= 0, "fallback limit cannot be negative")
    require(args.max_tokens >= 1, "token limit must be positive")
    require(args.max_elapsed_seconds >= 1, "elapsed-time limit must be positive")


def deny_new_work_if_circuit_open(state: dict[str, Any]) -> None:
    reasons = state["loss_circuit"]["reasons"]
    require(
        not state["loss_circuit"]["open"],
        f"loss circuit open: {', '.join(reasons) if reasons else 'limit reached'}",
    )


def evidence_satisfies(actual: str, required: str) -> bool:
    if required == "live":
        return actual == "live"
    return EVIDENCE_RANK[actual] >= EVIDENCE_RANK[required]


def add_loss_reason(state: dict[str, Any], reason: str) -> None:
    if reason not in state["loss_circuit"]["reasons"]:
        state["loss_circuit"]["reasons"].append(reason)
    state["loss_circuit"]["open"] = True


def route_for(state: dict[str, Any], scope: str) -> dict[str, Any]:
    return state["routes"].setdefault(
        scope,
        {
            "pending_failure": None,
            "active_attempt": None,
            "fallbacks_started": 0,
            "transient_retry_used": False,
            "circuit_open": False,
            "fingerprints": [],
        },
    )


def handle_evidence(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.verb == "add", "unknown evidence operation")
    require_text(args.id, "evidence id")
    require(args.id not in state["evidence"], "evidence id already exists")
    state["evidence"][args.id] = {
        "type": args.type,
        "claim": require_text(args.claim, "evidence claim"),
        "source": require_text(args.source, "evidence source"),
        "recorded_at": now_epoch(),
    }
    return f"ALLOW: recorded {args.type} evidence {args.id}", True


def handle_gate(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.gate in state["gates"], "unknown mandatory gate")
    gate = state["gates"][args.gate]
    if args.verb == "pass":
        require(args.evidence in state["evidence"], "gate evidence is not recorded")
        evidence = state["evidence"][args.evidence]
        require(
            evidence_satisfies(evidence["type"], gate["required_evidence"]),
            f"{evidence['type']} evidence cannot satisfy {gate['required_evidence']} gate",
        )
        gate.update(
            {
                "state": "passed",
                "evidence": [args.evidence],
                "symptom": None,
                "evidence_boundary": None,
            }
        )
        return f"ALLOW: gate {args.gate} passed with {args.evidence}", True

    require(args.verb == "fail", "unknown gate operation")
    gate.update(
        {
            "state": "failed",
            "symptom": require_text(args.symptom, "failure symptom"),
            "evidence_boundary": require_text(args.evidence_boundary, "evidence boundary"),
        }
    )
    return f"ALLOW: gate {args.gate} failed closed", True


def handle_phase(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.verb == "request", "unknown phase operation")
    deny_new_work_if_circuit_open(state)
    require(args.phase >= 0, "phase cannot be negative")
    require(args.depends_on in state["gates"], "unknown dependency gate")
    gate = state["gates"][args.depends_on]
    require(gate["state"] == "passed", f"dependent phase blocked by {gate['state']} gate")
    if args.worker:
        require(args.worker in state["workers"], "worker is not delegated")
        inherited = state["workers"][args.worker]["gates"].get(args.depends_on)
        require(inherited == "passed", "worker inherited an unpassed owner gate")
    return f"ALLOW: phase {args.phase} follows passed gate {args.depends_on}", False


def handle_delegate(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    deny_new_work_if_circuit_open(state)
    worker = require_text(args.worker, "worker")
    require(worker not in state["workers"], "worker already delegated")
    gate_states = {name: gate["state"] for name, gate in state["gates"].items()}
    state["workers"][worker] = {
        "delegated_at": now_epoch(),
        "gates": gate_states,
        "active_gate": state["active_gate"],
        "forbidden_dependencies": [
            name for name, gate_state in gate_states.items() if gate_state != "passed"
        ],
        "required_evidence": {
            name: gate["required_evidence"] for name, gate in state["gates"].items()
        },
        "limits": {
            "max_no_progress_rounds": state["limits"]["max_no_progress_rounds"],
            "max_fallbacks": state["limits"]["max_fallbacks"],
            "remaining_tokens": max(
                0, state["limits"]["max_tokens"] - state["limits"]["tokens_total"]
            ),
            "remaining_seconds": max(
                0,
                state["limits"]["max_elapsed_seconds"] - state["limits"]["elapsed_seconds"],
            ),
        },
    }
    return f"ALLOW: worker {worker} inherited owner constraints", True


def handle_failure(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.verb == "record", "unknown failure operation")
    failure_id = require_text(args.id, "failure id")
    scope = require_text(args.scope, "failure scope")
    require(failure_id not in state["failures"], "failure id already exists")
    route = route_for(state, scope)
    active = route["active_attempt"]
    if active is None:
        require(route["pending_failure"] is None, "previous failure still requires corrective action")
    else:
        require(active["action"] == args.action, "failure action differs from active attempt")
        require(
            active["fingerprint"] == args.fingerprint,
            "failure fingerprint differs from active attempt",
        )

    record = {
        "scope": scope,
        "action": require_text(args.action, "failed action"),
        "fingerprint": require_text(args.fingerprint, "failure fingerprint"),
        "classification": args.classification,
        "symptom": require_text(args.symptom, "failure symptom"),
        "inputs": require_text(args.inputs, "failure inputs"),
        "environment": require_text(args.environment, "failure environment"),
        "evidence_boundary": require_text(args.evidence_boundary, "evidence boundary"),
        "corrective_action": require_text(args.corrective_action, "corrective action"),
        "expected_evidence": require_text(args.expected_evidence, "expected evidence"),
        "recorded_at": now_epoch(),
        "was_fallback": bool(active and active["fallback_of"]),
    }
    state["failures"][failure_id] = record
    route["pending_failure"] = failure_id
    route["active_attempt"] = None
    if args.fingerprint not in route["fingerprints"]:
        route["fingerprints"].append(args.fingerprint)
    if record["was_fallback"] and route["fallbacks_started"] >= state["limits"]["max_fallbacks"]:
        route["circuit_open"] = True
    return f"ALLOW: learned failure {failure_id}; corrective action required", True


def handle_attempt(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    deny_new_work_if_circuit_open(state)
    scope = require_text(args.scope, "attempt scope")
    action = require_text(args.action, "attempt action")
    fingerprint = require_text(args.fingerprint, "attempt fingerprint")
    route = route_for(state, scope)
    require(not route["circuit_open"], "changed fallback already failed; route is closed")
    require(route["active_attempt"] is None, "another attempt is already active")
    pending_id = route["pending_failure"]

    if pending_id is None:
        require(not args.fallback_of, "fallback has no recorded failure")
        require(not args.transient_retry, "transient retry has no recorded transient failure")
    else:
        failure = state["failures"][pending_id]
        if args.transient_retry:
            require(failure["classification"] == "transient", "failure is not transient")
            require(not route["transient_retry_used"], "transient retry already used")
            require(fingerprint == failure["fingerprint"], "transient retry changed fingerprint")
            require(not args.fallback_of, "transient retry cannot also be a fallback")
            route["transient_retry_used"] = True
        else:
            require(args.fallback_of == pending_id, "failure requires its exact corrective fallback")
            changed_variable = require_text(args.changed_variable or "", "changed variable")
            require(
                changed_variable.lower() not in {"none", "retry", "same", "command"},
                "fallback change is not material",
            )
            require(fingerprint != failure["fingerprint"], "unchanged deterministic retry forbidden")
            require(
                route["fallbacks_started"] < state["limits"]["max_fallbacks"],
                "fallback budget exhausted",
            )
            route["fallbacks_started"] += 1

    route["active_attempt"] = {
        "action": action,
        "fingerprint": fingerprint,
        "fallback_of": args.fallback_of,
        "changed_variable": args.changed_variable,
        "transient_retry": args.transient_retry,
        "started_at": now_epoch(),
    }
    if fingerprint not in route["fingerprints"]:
        route["fingerprints"].append(fingerprint)
    return f"ALLOW: bounded attempt started for {scope}", True


def handle_success(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.verb == "record", "unknown success operation")
    scope = require_text(args.scope, "success scope")
    require(scope in state["routes"], "unknown attempt scope")
    route = state["routes"][scope]
    require(route["active_attempt"] is not None, "no active attempt to complete")
    if args.evidence:
        require(args.evidence in state["evidence"], "success evidence is not recorded")
    route["active_attempt"] = None
    route["pending_failure"] = None
    route["circuit_open"] = False
    return f"ALLOW: attempt succeeded for {scope}", True


def handle_progress(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.verb == "record", "unknown progress operation")
    deny_new_work_if_circuit_open(state)
    record = {
        "hypothesis": require_text(args.hypothesis, "hypothesis"),
        "action": require_text(args.action, "progress action"),
        "result": require_text(args.result, "progress result"),
        "changed_variable": require_text(args.changed_variable, "changed variable"),
        "stronger_evidence": args.stronger_evidence == "yes",
        "recorded_at": now_epoch(),
    }
    state["progress"].append(record)
    if record["stronger_evidence"]:
        state["limits"]["no_progress_rounds"] = 0
    else:
        state["limits"]["no_progress_rounds"] += 1
        if (
            state["limits"]["no_progress_rounds"]
            >= state["limits"]["max_no_progress_rounds"]
        ):
            add_loss_reason(state, "no-progress rounds exhausted")
    suffix = " loss circuit opened" if state["loss_circuit"]["open"] else ""
    return f"ALLOW: progress round recorded;{suffix}".rstrip(";"), True


def handle_budget(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.verb == "record", "unknown budget operation")
    require(args.tokens_total >= state["limits"]["tokens_total"], "token total moved backward")
    require(
        args.elapsed_seconds >= state["limits"]["elapsed_seconds"],
        "elapsed-time total moved backward",
    )
    state["limits"]["tokens_total"] = args.tokens_total
    state["limits"]["elapsed_seconds"] = args.elapsed_seconds
    if args.tokens_total >= state["limits"]["max_tokens"]:
        add_loss_reason(state, "token budget exhausted")
    if args.elapsed_seconds >= state["limits"]["max_elapsed_seconds"]:
        add_loss_reason(state, "elapsed-time budget exhausted")
    suffix = " loss circuit opened" if state["loss_circuit"]["open"] else ""
    return f"ALLOW: budget recorded;{suffix}".rstrip(";"), True


def handle_turn(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.verb == "set", "unknown turn operation")
    turn = require_text(args.turn, "current turn")
    require(turn != state["current_turn"], "turn is unchanged")
    state["current_turn"] = turn
    for grant in state["authorizations"]:
        if not grant["used"]:
            grant["expired"] = True
    return f"ALLOW: current turn advanced to {turn}; old grants expired", True


def validate_target_and_digest(target: str, digest: str) -> None:
    require_text(target, "exact target")
    require(".." not in target, "target is not canonical")
    require(bool(PAYLOAD_DIGEST.fullmatch(digest)), "payload digest must be sha256 plus 64 hex")


def handle_authorize(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.source == "current-user-turn", "plans, goals, and documents never authorize writes")
    require(args.turn == state["current_turn"], "authorization is not from the current turn")
    action = require_text(args.action, "exact action")
    target = require_text(args.target, "exact target")
    validate_target_and_digest(target, args.payload_digest)
    approval = require_text(args.approval, "user approval")
    require(len(approval) >= 4, "user approval evidence is too short")
    duplicate = any(
        not grant["used"]
        and not grant.get("expired", False)
        and grant["turn"] == args.turn
        and grant["action"] == action
        and grant["target"] == target
        and grant["payload_digest"] == args.payload_digest
        for grant in state["authorizations"]
    )
    require(not duplicate, "an unused exact authorization already exists")
    approval_digest = hashlib.sha256(approval.encode("utf-8")).hexdigest()
    state["authorizations"].append(
        {
            "id": str(uuid.uuid4()),
            "source": args.source,
            "turn": args.turn,
            "action": action,
            "target": target,
            "payload_digest": args.payload_digest,
            "approval_digest": f"sha256:{approval_digest}",
            "used": False,
            "expired": False,
            "created_at": now_epoch(),
        }
    )
    return "ALLOW: exact current-turn authorization recorded", True


def all_mandatory_gates_passed(state: dict[str, Any]) -> bool:
    return all(
        not gate["mandatory"] or gate["state"] == "passed"
        for gate in state["gates"].values()
    )


def handle_external_write(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.turn == state["current_turn"], "external write is not in the current turn")
    action = require_text(args.action, "exact action")
    target = require_text(args.target, "exact target")
    validate_target_and_digest(target, args.payload_digest)
    if args.kind in RELEASE_CLASSES:
        require(all_mandatory_gates_passed(state), f"{args.kind} blocked by unpassed mandatory gate")
    matches = [
        grant
        for grant in state["authorizations"]
        if not grant["used"]
        and not grant.get("expired", False)
        and grant["turn"] == args.turn
        and grant["action"] == action
        and grant["target"] == target
        and grant["payload_digest"] == args.payload_digest
    ]
    require(len(matches) == 1, "no single unused authorization matches action, target, and payload")
    grant = matches[0]
    grant["used"] = True
    grant["used_at"] = now_epoch()
    state["writes"].append(
        {
            "authorization_id": grant["id"],
            "turn": args.turn,
            "kind": args.kind,
            "action": action,
            "target": target,
            "payload_digest": args.payload_digest,
            "recorded_at": now_epoch(),
        }
    )
    return "ALLOW: exact external write authorized once", True


def handle_artifact(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    require(args.verb == "add", "unknown artifact operation")
    deny_new_work_if_circuit_open(state)
    artifact_path = require_text(args.path, "artifact path")
    criterion = require_text(args.exit_criterion, "mapped exit criterion")
    valid_criteria = {state["outcome"]["direct_proof"], *state["gates"].keys()}
    require(criterion in valid_criteria, "artifact does not map to an active exit criterion")
    state["artifacts"].append(
        {
            "path": artifact_path,
            "exit_criterion": criterion,
            "recorded_at": now_epoch(),
        }
    )
    return f"ALLOW: artifact maps to {criterion}", True


def handle_wait(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    wait_id = require_text(args.id, "wait id")
    if args.verb == "register":
        deny_new_work_if_circuit_open(state)
        owner = require_text(args.owner, "wait owner")
        require(wait_id not in state["waits"], "wait id already exists")
        require(args.expires_at >= 0, "wait expiry cannot be negative")
        state["waits"][wait_id] = {
            "owner": owner,
            "expires_at": args.expires_at,
            "registered_at": now_epoch(),
        }
        return f"ALLOW: bounded wait {wait_id} registered", True
    if args.verb == "cleanup":
        expired = [
            name
            for name, wait in state["waits"].items()
            if wait["expires_at"] <= args.now
        ]
        for name in expired:
            del state["waits"][name]
        return f"ALLOW: cleaned {len(expired)} expired waits", bool(expired)

    require(args.verb == "require", "unknown wait operation")
    require(wait_id in state["waits"], "wait does not exist")
    require(state["waits"][wait_id]["owner"] == args.owner, "wait owner mismatch")
    require(state["waits"][wait_id]["expires_at"] > now_epoch(), "wait expired")
    return f"ALLOW: wait {wait_id} exists for {args.owner}", False


def render_status(state: dict[str, Any]) -> str:
    gates = state["gates"]
    failed = [(name, gate) for name, gate in gates.items() if gate["state"] == "failed"]
    open_gates = [(name, gate) for name, gate in gates.items() if gate["state"] != "passed"]
    if failed:
        outcome = "DOES NOT WORK"
        evidence_line = "; ".join(
            f"{name}: {gate['symptom']} ({gate['evidence_boundary']})"
            for name, gate in failed
        )
    elif not open_gates:
        outcome = "WORKS"
        evidence_line = "; ".join(
            f"{name}: {','.join(gate['evidence'])}" for name, gate in gates.items()
        )
    else:
        outcome = "NOT PROVEN"
        evidence_line = "; ".join(
            f"{name}: missing {gate['required_evidence']} proof" for name, gate in open_gates
        )
    circuit = (
        ", ".join(state["loss_circuit"]["reasons"])
        if state["loss_circuit"]["open"]
        else "closed"
    )
    return "\n".join(
        [
            f"OUTCOME: {outcome}",
            f"EVIDENCE: {evidence_line}",
            f"LOSS CIRCUIT: {circuit}",
            f"EXTERNAL WRITES: {len(state['writes'])}",
        ]
    )


def dispatch(state: dict[str, Any], args: argparse.Namespace) -> tuple[str, bool]:
    handlers = {
        "evidence": handle_evidence,
        "gate": handle_gate,
        "phase": handle_phase,
        "delegate": handle_delegate,
        "failure": handle_failure,
        "attempt": handle_attempt,
        "success": handle_success,
        "progress": handle_progress,
        "budget": handle_budget,
        "turn": handle_turn,
        "authorize": handle_authorize,
        "external-write": handle_external_write,
        "artifact": handle_artifact,
        "wait": handle_wait,
    }
    if args.command == "status":
        return render_status(state), False
    if args.command == "show":
        return json.dumps(state, indent=2, sort_keys=True), False
    require(args.command in handlers, "unknown execution-control command")
    return handlers[args.command](state, args)


def add_evidence_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser("evidence")
    verbs = parser.add_subparsers(dest="verb", required=True)
    add = verbs.add_parser("add")
    add.add_argument("--id", required=True)
    add.add_argument("--type", choices=sorted(EVIDENCE_RANK), required=True)
    add.add_argument("--claim", required=True)
    add.add_argument("--source", required=True)


def add_gate_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser("gate")
    verbs = parser.add_subparsers(dest="verb", required=True)
    passed = verbs.add_parser("pass")
    passed.add_argument("--gate", required=True)
    passed.add_argument("--evidence", required=True)
    failed = verbs.add_parser("fail")
    failed.add_argument("--gate", required=True)
    failed.add_argument("--symptom", required=True)
    failed.add_argument("--evidence-boundary", required=True)


def add_failure_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser("failure")
    verbs = parser.add_subparsers(dest="verb", required=True)
    record = verbs.add_parser("record")
    record.add_argument("--id", required=True)
    record.add_argument("--scope", required=True)
    record.add_argument("--action", required=True)
    record.add_argument("--fingerprint", required=True)
    record.add_argument(
        "--classification",
        choices=[
            "transient",
            "deterministic",
            "code-config",
            "environment",
            "permission",
            "external-dependency",
        ],
        required=True,
    )
    record.add_argument("--symptom", required=True)
    record.add_argument("--inputs", required=True)
    record.add_argument("--environment", required=True)
    record.add_argument("--evidence-boundary", required=True)
    record.add_argument("--corrective-action", required=True)
    record.add_argument("--expected-evidence", required=True)


def add_wait_parser(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser("wait")
    verbs = parser.add_subparsers(dest="verb", required=True)
    register = verbs.add_parser("register")
    register.add_argument("--id", required=True)
    register.add_argument("--owner", required=True)
    register.add_argument("--expires-at", type=int, required=True)
    cleanup = verbs.add_parser("cleanup")
    cleanup.add_argument("--now", type=int, required=True)
    cleanup.add_argument("--id", default="cleanup")
    require_wait = verbs.add_parser("require")
    require_wait.add_argument("--id", required=True)
    require_wait.add_argument("--owner", required=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, help="Per-task durable execution state")
    commands = parser.add_subparsers(dest="command", required=True)

    init = commands.add_parser("init")
    init.add_argument("--outcome", required=True)
    init.add_argument("--direct-proof", required=True)
    init.add_argument("--gate", required=True)
    init.add_argument("--required-evidence", choices=sorted(EVIDENCE_RANK), required=True)
    init.add_argument("--turn", required=True)
    init.add_argument(
        "--max-no-progress-rounds",
        type=int,
        default=DEFAULT_MAX_NO_PROGRESS_ROUNDS,
    )
    init.add_argument("--max-fallbacks", type=int, default=DEFAULT_MAX_FALLBACKS)
    init.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    init.add_argument(
        "--max-elapsed-seconds",
        type=int,
        default=DEFAULT_MAX_ELAPSED_SECONDS,
    )

    add_evidence_parser(commands)
    add_gate_parser(commands)

    phase = commands.add_parser("phase")
    phase_verbs = phase.add_subparsers(dest="verb", required=True)
    phase_request = phase_verbs.add_parser("request")
    phase_request.add_argument("--phase", type=int, required=True)
    phase_request.add_argument("--depends-on", required=True)
    phase_request.add_argument("--worker")

    delegate = commands.add_parser("delegate")
    delegate.add_argument("--worker", required=True)

    add_failure_parser(commands)

    attempt = commands.add_parser("attempt")
    attempt.add_argument("--scope", required=True)
    attempt.add_argument("--action", required=True)
    attempt.add_argument("--fingerprint", required=True)
    attempt.add_argument("--fallback-of")
    attempt.add_argument("--changed-variable")
    attempt.add_argument("--transient-retry", action="store_true")

    success = commands.add_parser("success")
    success_verbs = success.add_subparsers(dest="verb", required=True)
    success_record = success_verbs.add_parser("record")
    success_record.add_argument("--scope", required=True)
    success_record.add_argument("--evidence")

    progress = commands.add_parser("progress")
    progress_verbs = progress.add_subparsers(dest="verb", required=True)
    progress_record = progress_verbs.add_parser("record")
    progress_record.add_argument("--hypothesis", required=True)
    progress_record.add_argument("--action", required=True)
    progress_record.add_argument("--result", required=True)
    progress_record.add_argument("--changed-variable", required=True)
    progress_record.add_argument("--stronger-evidence", choices=["yes", "no"], required=True)

    budget = commands.add_parser("budget")
    budget_verbs = budget.add_subparsers(dest="verb", required=True)
    budget_record = budget_verbs.add_parser("record")
    budget_record.add_argument("--tokens-total", type=int, required=True)
    budget_record.add_argument("--elapsed-seconds", type=int, required=True)

    turn = commands.add_parser("turn")
    turn_verbs = turn.add_subparsers(dest="verb", required=True)
    turn_set = turn_verbs.add_parser("set")
    turn_set.add_argument("--turn", required=True)

    authorize = commands.add_parser("authorize")
    authorize.add_argument(
        "--source",
        choices=["current-user-turn", "plan", "goal", "document", "agent"],
        required=True,
    )
    authorize.add_argument("--turn", required=True)
    authorize.add_argument("--action", required=True)
    authorize.add_argument("--target", required=True)
    authorize.add_argument("--payload-digest", required=True)
    authorize.add_argument("--approval", required=True)

    external_write = commands.add_parser("external-write")
    external_write.add_argument("--turn", required=True)
    external_write.add_argument("--kind", choices=["external", *sorted(RELEASE_CLASSES)], default="external")
    external_write.add_argument("--action", required=True)
    external_write.add_argument("--target", required=True)
    external_write.add_argument("--payload-digest", required=True)

    artifact = commands.add_parser("artifact")
    artifact_verbs = artifact.add_subparsers(dest="verb", required=True)
    artifact_add = artifact_verbs.add_parser("add")
    artifact_add.add_argument("--path", required=True)
    artifact_add.add_argument("--exit-criterion", required=True)

    add_wait_parser(commands)
    commands.add_parser("status")
    commands.add_parser("show")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    state_path = Path(args.state).expanduser()
    try:
        with locked_state(state_path):
            if args.command == "init":
                require(not state_path.exists(), "execution state already exists; reset is forbidden")
                validate_init_limits(args)
                state = new_state(args)
                save_state(state_path, state)
                message = f"ALLOW: initialized fail-closed execution {state['execution_id']}"
            else:
                state = load_state(state_path)
                message, changed = dispatch(state, args)
                if changed:
                    save_state(state_path, state)
        print(message)
        return 0
    except PolicyDenied as error:
        print(f"DENY: {error}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
