#!/usr/bin/env python3
"""Host hook that intercepts external mutations before execution.

Authorization is decided synchronously by a native user prompt bound to the
actual tool name, target, and input digest. UserPromptSubmit text and
caller-provided state are never authorization inputs.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator


VERSION = 1
MAX_STDIN_BYTES = 4 * 1024 * 1024
MAX_HISTORY = 100
MAX_RECEIPTS = 50
MUTATION_VERBS = {
    "add", "approve", "archive", "assign", "cancel", "close", "comment",
    "create", "delete", "deploy", "disable", "edit", "enable", "forward",
    "install", "invite", "label", "link", "merge", "move", "patch", "post",
    "publish", "purchase", "push", "release", "remove", "rename", "reopen",
    "reply", "request", "restore", "revoke", "save", "send", "set", "share",
    "submit", "transition", "trash", "unlink", "uninstall", "unlabel",
    "update", "upload",
}
EXTERNAL_MARKERS = {
    "atlassian", "automation", "box", "calendar", "codex_apps", "confluence",
    "drive", "figma", "github", "gmail", "jira", "linear", "notion",
    "openai_platform", "outlook", "plugin_management", "sharepoint", "sites",
    "slack", "teams", "thread",
}
SAFE_TOOL_NAMES = {
    "apply_patch",
    "collaboration.followup_task",
    "collaboration.interrupt_agent",
    "collaboration.list_agents",
    "collaboration.send_message",
    "collaboration.spawn_agent",
    "collaboration.wait_agent",
    "functions.apply_patch",
    "functions.get_goal",
    "functions.list_mcp_resource_templates",
    "functions.list_mcp_resources",
    "functions.read_mcp_resource",
    "functions.request_user_input",
    "functions.update_plan",
    "get_goal",
    "mcp__node_repl__js",
    "request_user_input",
    "update_plan",
    "web.run",
}
READ_ONLY_VERBS = {
    "check", "count", "describe", "download", "fetch", "find", "get",
    "inspect", "list", "lookup", "open", "query", "read", "search", "show",
    "status", "stats", "view", "wait",
}
OPAQUE_EXECUTION_VERBS = {
    "batch", "call", "eval", "execute", "graphql", "invoke", "request", "run",
}
TARGET_KEYS = (
    "repo_full_name", "repository", "repo", "owner", "project_id", "site_id",
    "thread_id", "pr_number", "issue_number", "message_id", "comment_id",
    "channel_id", "channel", "to", "recipients", "target", "url", "path",
    "plugin_id", "slug", "name",
)
SECRET_KEY_PATTERN = re.compile(
    r"(authorization|cookie|credential|password|secret|token|api[_-]?key)",
    re.IGNORECASE,
)
SHELL_TOOL_PATTERN = re.compile(
    r"(^|[._:])(bash|exec|exec_command|local_shell|shell|shell_command)$",
    re.IGNORECASE,
)
SHELL_MUTATION_PATTERNS = (
    re.compile(r"\bgit\b(?:(?![;&|]).){0,300}\bpush\b", re.IGNORECASE),
    re.compile(
        r"\bgh\s+(api|issue|pr|release|repo)\b.*"
        r"(\s-X\s*(POST|PUT|PATCH|DELETE)\b|\s--method[=\s]+(POST|PUT|PATCH|DELETE)\b|"
        r"\s(-f|-F|--field|--raw-field|--input)\b|"
        r"\b(create|edit|close|reopen|comment|review|merge|delete|upload)\b)",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(r"\b(npm|pnpm|yarn)\s+(publish|unpublish|deprecate)\b", re.IGNORECASE),
    re.compile(r"\bpython(?:\d+(?:\.\d+)*)?\s+-m\s+twine\s+upload\b", re.IGNORECASE),
    re.compile(
        r"\bpython(?:\d+(?:\.\d+)*)?\b(?:(?![;&|]).){0,300}"
        r"\b(publish|deploy|upload|release|push|send|delete|remove|update)[-_a-z0-9.]*",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bpython(?:\d+(?:\.\d+)*)?\b(?:(?![;&|]).){0,120}\s-c\b",
        re.IGNORECASE,
    ),
    re.compile(r"\b(docker|podman)\s+push\b", re.IGNORECASE),
    re.compile(
        r"\bkubectl\s+(apply|create|delete|edit|label|annotate|patch|replace|scale|set)\b",
        re.IGNORECASE,
    ),
    re.compile(r"\bterraform\s+(apply|destroy|import)\b", re.IGNORECASE),
    re.compile(r"\b(vercel|netlify|flyctl)\s+(deploy|publish|remove|destroy)\b", re.IGNORECASE),
    re.compile(
        r"\bxcrun\s+(notarytool\s+submit|altool\b.*--upload-app|"
        r"iTMSTransporter\b.*(?:-m\s+upload|-upload))",
        re.IGNORECASE | re.DOTALL,
    ),
    re.compile(
        r"\bfastlane\s+(pilot|deliver|upload_to_app_store|upload_to_testflight|supply)\b",
        re.IGNORECASE,
    ),
    re.compile(r"\b(ssh|scp|sftp)\b", re.IGNORECASE),
    re.compile(r"\brsync\b.*\S+@\S+:", re.IGNORECASE | re.DOTALL),
    re.compile(
        r"\bcurl\b.*(\s-X\s*(POST|PUT|PATCH|DELETE)\b|\s--request[=\s]+"
        r"(POST|PUT|PATCH|DELETE)\b|\s(-d|--data|--data-raw|--form)\b)",
        re.IGNORECASE | re.DOTALL,
    ),
)
PAYLOAD_MUTATION_PATTERN = re.compile(
    r"\bmutation\b|"
    r"(?i:\"(?:action|method|operation|verb)\"\s*:\s*\"[^\"]*"
    r"(?:approve|archive|close|comment|create|delete|deploy|edit|install|merge|"
    r"move|patch|post|publish|push|release|remove|reply|restore|send|set|share|"
    r"submit|transition|trash|uninstall|update|upload)[^\"]*\")",
    re.IGNORECASE,
)


class StateTamperError(RuntimeError):
    """Raised when the signed host audit state does not verify."""


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def payload_digest(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def _bounded(value: Any, limit: int = 160) -> str:
    text = str(value)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _redacted(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: ("<redacted>" if SECRET_KEY_PATTERN.search(str(key)) else _redacted(item))
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_redacted(item) for item in value]
    return value


def _tool_tokens(tool_name: str) -> set[str]:
    return {
        token
        for token in re.split(r"[^a-z0-9]+", tool_name.lower())
        if token
    }


def _shell_command(tool_input: dict[str, Any]) -> str:
    for key in ("cmd", "command", "script", "code"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    return ""


def is_external_mutation(tool_name: str, tool_input: dict[str, Any]) -> bool:
    normalized = tool_name.strip().lower()
    if normalized in SAFE_TOOL_NAMES or normalized.startswith("collaboration."):
        return False
    if normalized in {"exec", "functions.exec"}:
        return True
    if SHELL_TOOL_PATTERN.search(normalized):
        command = _shell_command(tool_input)
        return any(pattern.search(command) for pattern in SHELL_MUTATION_PATTERNS)
    tokens = _tool_tokens(normalized)
    is_external = (
        normalized.startswith("mcp__")
        or any(marker in normalized for marker in EXTERNAL_MARKERS)
    )
    if not is_external:
        return False
    if tokens & (MUTATION_VERBS | OPAQUE_EXECUTION_VERBS):
        return True
    if PAYLOAD_MUTATION_PATTERN.search(canonical_json(tool_input)):
        return True
    return not bool(tokens & READ_ONLY_VERBS)


def exact_target(tool_name: str, tool_input: dict[str, Any], cwd: str = "") -> str | None:
    if SHELL_TOOL_PATTERN.search(tool_name.lower()):
        command = _shell_command(tool_input)
        if not command:
            return None
        return f"cwd={cwd or '<unknown>'}; command={_bounded(command, 300)}"
    fields = {
        key: tool_input[key]
        for key in TARGET_KEYS
        if key in tool_input and tool_input[key] not in (None, "", [], {})
    }
    if not fields:
        return None
    if len(fields) == 1:
        return _bounded(next(iter(fields.values())), 300)
    return _bounded(canonical_json(fields), 500)


def _session_id(hook_input: dict[str, Any]) -> str | None:
    for key in ("session_id", "sessionId", "thread_id", "conversation_id"):
        value = hook_input.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    transcript = hook_input.get("transcript_path")
    if isinstance(transcript, str) and transcript.strip():
        return "transcript:" + hashlib.sha256(transcript.encode("utf-8")).hexdigest()
    return None


def _decision(allowed: bool, reason: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow" if allowed else "deny",
            "permissionDecisionReason": reason,
        }
    }


class MacOSApprovalBroker:
    """Synchronous, user-presence approval bound to one actual tool invocation."""

    def __init__(self, timeout_seconds: int = 180) -> None:
        self.timeout_seconds = timeout_seconds

    def approve(self, request: dict[str, Any]) -> bool:
        if sys.platform != "darwin" or not Path("/usr/bin/osascript").is_file():
            return False
        message = (
            "External mutation requested\n\n"
            f"Action: {request['action']}\n"
            f"Target: {request['target']}\n"
            f"Payload: {request['payload_digest']}\n"
            f"Input preview: {request['payload_preview']}\n\n"
            "Allow this exact call once?"
        )
        script = """
on run argv
  try
    set answer to display dialog (item 1 of argv) with title "ClosedDexter approval" buttons {"Deny", "Allow"} default button "Deny" cancel button "Deny" with icon caution giving up after 180
    if gave up of answer then return "DENY"
    if button returned of answer is "Allow" then return "ALLOW"
    return "DENY"
  on error
    return "DENY"
  end try
end run
"""
        try:
            result = subprocess.run(
                ["/usr/bin/osascript", "-e", script, message],
                check=False,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds + 5,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        return result.returncode == 0 and result.stdout.strip() == "ALLOW"


class HookRuntime:
    def __init__(
        self,
        root: Path,
        *,
        approver: Any | None = None,
        provider: str = "host",
        clock: Callable[[], float] = time.time,
    ) -> None:
        raw_root = Path(root).expanduser()
        self.root = raw_root.resolve()
        raw_parent = raw_root.parent
        resolved_parent = self.root.parent
        self.protected_path_strings = {
            str(raw_root),
            str(raw_parent),
            str(self.root),
            str(resolved_parent),
        }
        self.protected_path_strings.update(
            path.removeprefix("/private")
            for path in tuple(self.protected_path_strings)
            if path.startswith("/private/var/")
        )
        self.approver = approver
        self.provider = provider
        self.clock = clock
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        self.key_path = self.root / ".signing-key"
        self._key = self._load_or_create_key()

    def _load_or_create_key(self) -> bytes:
        try:
            descriptor = os.open(
                self.key_path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
        except FileExistsError:
            pass
        else:
            try:
                os.write(descriptor, secrets.token_bytes(32))
            finally:
                os.close(descriptor)
        os.chmod(self.key_path, 0o600)
        key = self.key_path.read_bytes()
        if len(key) != 32:
            raise StateTamperError("host signing key has an invalid size")
        return key

    def _signature(self, state: dict[str, Any]) -> str:
        unsigned = {key: value for key, value in state.items() if key != "_signature"}
        return hmac.new(
            self._key,
            canonical_json(unsigned).encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

    def _default_state(self, session_id: str) -> dict[str, Any]:
        return {
            "version": VERSION,
            "provider": self.provider,
            "session_id": session_id,
            "current_turn": 0,
            "inflight": [],
            "receipts": [],
            "history": [],
        }

    def session_path(self, hook_input: dict[str, Any]) -> Path:
        session_id = _session_id(hook_input)
        if not session_id:
            raise ValueError("trusted host session identifier unavailable")
        key = hashlib.sha256(
            f"{self.provider}\0{session_id}".encode("utf-8")
        ).hexdigest()
        return self.root / f"{key}.json"

    @contextmanager
    def _locked(self, hook_input: dict[str, Any]) -> Iterator[Path]:
        state_path = self.session_path(hook_input)
        lock_path = state_path.with_suffix(".lock")
        with lock_path.open("a+b") as lock:
            os.chmod(lock_path, 0o600)
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                yield state_path
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _read_path(self, state_path: Path, session_id: str) -> dict[str, Any]:
        if not state_path.exists():
            return self._default_state(session_id)
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise StateTamperError("host audit state is unreadable or tampered") from error
        supplied = state.get("_signature")
        if not isinstance(supplied, str) or not hmac.compare_digest(
            supplied, self._signature(state)
        ):
            raise StateTamperError("host audit state signature indicates tampering")
        if state.get("session_id") != session_id or state.get("provider") != self.provider:
            raise StateTamperError("host audit state identity indicates tampering")
        return state

    def _write_path(self, state_path: Path, state: dict[str, Any]) -> None:
        state = dict(state)
        state["_signature"] = self._signature(state)
        temporary = state_path.with_suffix(f".{os.getpid()}.{secrets.token_hex(4)}.tmp")
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(state, stream, ensure_ascii=False, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, state_path)
            os.chmod(state_path, 0o600)
        finally:
            temporary.unlink(missing_ok=True)

    def read_session(self, hook_input: dict[str, Any]) -> dict[str, Any]:
        session_id = _session_id(hook_input)
        if not session_id:
            raise ValueError("trusted host session identifier unavailable")
        with self._locked(hook_input) as state_path:
            return self._read_path(state_path, session_id)

    def _append_history(self, state: dict[str, Any], event: dict[str, Any]) -> None:
        state.setdefault("history", []).append({"at": self.clock(), **event})
        state["history"] = state["history"][-MAX_HISTORY:]

    def _protected_reference(
        self,
        tool_name: str,
        tool_input: dict[str, Any],
    ) -> bool:
        serialized = canonical_json(tool_input)
        task_ledger_marker = "/".join((".closed-dexter", "execution-state"))
        source_hook_marker = "agent-execution-" + "hook.py"
        markers = {
            marker
            for marker in self.protected_path_strings | {
            ".closed-dexter/execution-state",
            "agent-execution-hook.py",
            }
            if task_ledger_marker not in marker and marker != source_hook_marker
        }
        if any(marker in serialized for marker in markers):
            return True
        normalized = tool_name.lower()
        if "apply_patch" in normalized or SHELL_TOOL_PATTERN.search(normalized):
            return any(
                marker in serialized
                for marker in (
                    ".codex/hooks.json",
                    ".claude/settings.json",
                    ".codex/hooks/agent-execution-hook.py",
                    ".claude/hooks/agent-execution-hook.py",
                )
            )
        return False

    def _user_prompt(self, hook_input: dict[str, Any]) -> dict[str, Any]:
        session_id = _session_id(hook_input)
        if not session_id:
            return {}
        prompt = hook_input.get("prompt")
        prompt_hash = payload_digest(prompt if isinstance(prompt, str) else "")
        with self._locked(hook_input) as state_path:
            state = self._read_path(state_path, session_id)
            state["current_turn"] = int(state.get("current_turn", 0)) + 1
            self._append_history(
                state,
                {
                    "event": "user_prompt_observed",
                    "prompt_digest": prompt_hash,
                    "note": "audit only; prompt text never grants authorization",
                },
            )
            self._write_path(state_path, state)
        return {}

    def _pre_tool(self, hook_input: dict[str, Any]) -> dict[str, Any]:
        tool_name = str(hook_input.get("tool_name") or "")
        raw_tool_input = hook_input.get("tool_input")
        tool_input = raw_tool_input if isinstance(raw_tool_input, dict) else {}
        if self._protected_reference(tool_name, tool_input):
            return _decision(False, "DENY: protected execution control files are host-owned.")
        if not is_external_mutation(tool_name, tool_input):
            return {}
        session_id = _session_id(hook_input)
        if not session_id:
            return _decision(False, "DENY: trusted host session identifier unavailable.")
        target = exact_target(tool_name, tool_input, str(hook_input.get("cwd") or ""))
        if not target:
            return _decision(False, "DENY: exact external mutation target is absent.")
        digest = payload_digest(tool_input)
        request = {
            "authorization_id": secrets.token_hex(16),
            "session_id": session_id,
            "action": tool_name,
            "target": target,
            "payload_digest": digest,
            "payload_preview": _bounded(canonical_json(_redacted(tool_input)), 900),
            "turn": None,
        }
        try:
            with self._locked(hook_input) as state_path:
                state = self._read_path(state_path, session_id)
                request["turn"] = state.get("current_turn", 0)
                if self.approver is None:
                    self._append_history(
                        state,
                        {
                            "event": "external_mutation_denied",
                            "reason": "host approval unavailable",
                            "action": tool_name,
                            "target": target,
                            "input_digest": digest,
                        },
                    )
                    self._write_path(state_path, state)
                    return _decision(False, "DENY: host approval unavailable.")
                approved = bool(self.approver.approve(dict(request)))
                self._append_history(
                    state,
                    {
                        "event": "external_mutation_authorization",
                        "approved": approved,
                        "authorization_id": request["authorization_id"],
                        "action": tool_name,
                        "target": target,
                        "input_digest": digest,
                        "turn": request["turn"],
                    },
                )
                if approved:
                    state.setdefault("inflight", []).append(
                        {
                            "authorization_id": request["authorization_id"],
                            "action": tool_name,
                            "target": target,
                            "input_digest": digest,
                            "turn": request["turn"],
                            "approved_at": self.clock(),
                        }
                    )
                    state["inflight"] = state["inflight"][-20:]
                self._write_path(state_path, state)
        except StateTamperError as error:
            return _decision(False, f"DENY: host audit state tamper detected: {error}.")
        if not approved:
            return _decision(False, "DENY: user rejected this exact external mutation.")
        return _decision(True, "ALLOW ONCE: native user approval matched this action, target, and payload.")

    def _post_tool(
        self,
        hook_input: dict[str, Any],
        *,
        forced_error: bool = False,
    ) -> dict[str, Any]:
        session_id = _session_id(hook_input)
        if not session_id:
            return {}
        tool_name = str(hook_input.get("tool_name") or "")
        raw_tool_input = hook_input.get("tool_input")
        tool_input = raw_tool_input if isinstance(raw_tool_input, dict) else {}
        digest = payload_digest(tool_input)
        response = hook_input.get(
            "tool_response",
            hook_input.get("tool_output", hook_input.get("error")),
        )
        try:
            with self._locked(hook_input) as state_path:
                state = self._read_path(state_path, session_id)
                inflight = state.setdefault("inflight", [])
                matching_index = next(
                    (
                        index
                        for index, item in enumerate(inflight)
                        if item.get("action") == tool_name
                        and item.get("input_digest") == digest
                    ),
                    None,
                )
                if matching_index is None:
                    return {}
                authorization = inflight.pop(matching_index)
                is_error = forced_error or hook_input.get("is_error") is True
                if isinstance(response, dict) and response.get("error"):
                    is_error = True
                if isinstance(response, str) and re.search(
                    r"\b(error|failed|failure|denied|forbidden|unauthori[sz]ed)\b",
                    response,
                    re.IGNORECASE,
                ):
                    is_error = True
                explicitly_successful = (
                    hook_input.get("is_error") is False
                    or (
                        isinstance(response, dict)
                        and (
                            response.get("success") is True
                            or response.get("ok") is True
                            or str(response.get("status") or "").lower()
                            in {"complete", "completed", "ok", "success", "succeeded"}
                        )
                    )
                )
                result = (
                    "provider_reported_failure"
                    if is_error
                    else (
                        "provider_reported_success"
                        if explicitly_successful
                        else "provider_reported_unknown"
                    )
                )
                receipt = {
                    **authorization,
                    "completed_at": self.clock(),
                    "result": result,
                    "response_digest": payload_digest(response),
                }
                state.setdefault("receipts", []).append(receipt)
                state["receipts"] = state["receipts"][-MAX_RECEIPTS:]
                self._append_history(
                    state,
                    {
                        "event": "external_mutation_receipt",
                        "authorization_id": authorization["authorization_id"],
                        "result": receipt["result"],
                        "response_digest": receipt["response_digest"],
                    },
                )
                self._write_path(state_path, state)
        except StateTamperError:
            return {}
        return {}

    def handle(self, event: str, hook_input: dict[str, Any]) -> dict[str, Any]:
        if event == "UserPromptSubmit":
            try:
                return self._user_prompt(hook_input)
            except StateTamperError:
                return {}
        if event == "PreToolUse":
            return self._pre_tool(hook_input)
        if event == "PostToolUse":
            return self._post_tool(hook_input)
        if event == "PostToolUseFailure":
            return self._post_tool(hook_input, forced_error=True)
        return {}


def _read_hook_input() -> dict[str, Any]:
    raw = sys.stdin.buffer.read(MAX_STDIN_BYTES + 1)
    if len(raw) > MAX_STDIN_BYTES:
        raise ValueError("hook input exceeds size limit")
    parsed = json.loads(raw.decode("utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError("hook input must be a JSON object")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--event",
        required=True,
        choices=(
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PostToolUseFailure",
        ),
    )
    parser.add_argument("--provider", choices=("codex", "claude"), default="codex")
    args = parser.parse_args()
    try:
        hook_input = _read_hook_input()
        root_override = os.environ.get("CLOSED_DEXTER_EXECUTION_STATE_ROOT")
        root = (
            Path(root_override)
            if root_override
            else Path.home() / ".closed-dexter" / "execution-state" / "host"
        )
        runtime = HookRuntime(
            root,
            approver=MacOSApprovalBroker(),
            provider=args.provider,
        )
        result = runtime.handle(args.event, hook_input)
    except Exception as error:
        if args.event == "PreToolUse":
            result = _decision(False, f"DENY: execution-control hook failed closed: {error}.")
        else:
            result = {}
    sys.stdout.write(canonical_json(result) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
