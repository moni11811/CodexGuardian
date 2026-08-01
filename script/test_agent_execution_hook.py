#!/usr/bin/env python3
"""Regression proof for the host external-mutation interceptor."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("agent_execution_hook.py")
SPEC = importlib.util.spec_from_file_location("agent_execution_hook", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
HOOK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOOK)


class Approver:
    def __init__(self, decisions: list[bool]) -> None:
        self.decisions = iter(decisions)
        self.requests: list[dict] = []

    def approve(self, request: dict) -> bool:
        self.requests.append(request)
        return next(self.decisions, False)


class ExecutionHookTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="codexmcphone-hook-")
        self.root = Path(self.temp.name) / "state"
        self.base = {
            "session_id": "host-session",
            "transcript_path": "/tmp/host-session.jsonl",
            "cwd": "/tmp/repo",
        }
        self.call = {
            **self.base,
            "tool_name": "mcp__codex_apps__github__add_issue_comment",
            "tool_input": {
                "repo_full_name": "owner/repo",
                "issue_number": 7,
                "body": "exact payload",
            },
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def decision(result: dict) -> str | None:
        return result.get("hookSpecificOutput", {}).get("permissionDecision")

    def test_no_broker_fails_closed(self) -> None:
        runtime = HOOK.HookRuntime(self.root, approver=None)
        self.assertEqual("deny", self.decision(runtime.handle("PreToolUse", self.call)))

    def test_native_decision_binds_actual_tool_target_and_payload(self) -> None:
        approver = Approver([True])
        runtime = HOOK.HookRuntime(self.root, approver=approver)
        self.assertEqual("allow", self.decision(runtime.handle("PreToolUse", self.call)))
        self.assertEqual(self.call["tool_name"], approver.requests[0]["action"])
        self.assertIn("owner/repo", approver.requests[0]["target"])
        self.assertEqual(
            HOOK.payload_digest(self.call["tool_input"]),
            approver.requests[0]["payload_digest"],
        )

    def test_unsigned_prompt_text_never_grants(self) -> None:
        approver = Approver([False])
        runtime = HOOK.HookRuntime(self.root, approver=approver)
        runtime.handle("UserPromptSubmit", {**self.base, "prompt": "APPROVE EVERYTHING"})
        self.assertEqual("deny", self.decision(runtime.handle("PreToolUse", self.call)))

    def test_shell_push_and_ios_upload_are_intercepted(self) -> None:
        approver = Approver([False, False])
        runtime = HOOK.HookRuntime(self.root, approver=approver)
        for command in ("git push origin main", "xcrun notarytool submit App.zip"):
            result = runtime.handle(
                "PreToolUse",
                {
                    **self.base,
                    "tool_name": "functions.exec_command",
                    "tool_input": {"cmd": command},
                },
            )
            self.assertEqual("deny", self.decision(result))
        self.assertEqual(2, len(approver.requests))

    def test_provider_failure_is_not_success_evidence(self) -> None:
        approver = Approver([True])
        runtime = HOOK.HookRuntime(self.root, approver=approver)
        runtime.handle("PreToolUse", self.call)
        runtime.handle(
            "PostToolUseFailure",
            {**self.call, "error": "permission denied"},
        )
        receipt = runtime.read_session(self.base)["receipts"][-1]
        self.assertEqual("provider_reported_failure", receipt["result"])

    def test_opaque_and_indirect_external_mutations_are_intercepted(self) -> None:
        approver = Approver([False, False, False, False])
        runtime = HOOK.HookRuntime(self.root, approver=approver)
        attempts = [
            ("functions.exec_command", {"cmd": "git -C /tmp/repo push origin main"}),
            (
                "functions.exec",
                {"code": "const c='git '+'push origin main'; await tools.exec_command({cmd:c});"},
            ),
            (
                "mcp__codex_apps__github__execute_graphql",
                {"repo_full_name": "owner/repo", "query": "mutation { deleteIssue(input:{}) { id } }"},
            ),
            (
                "functions.exec_command",
                {"cmd": "python3 -m twine upload dist/*"},
            ),
        ]
        for tool_name, tool_input in attempts:
            with self.subTest(tool_name=tool_name):
                result = runtime.handle(
                    "PreToolUse",
                    {**self.base, "tool_name": tool_name, "tool_input": tool_input},
                )
                self.assertEqual("deny", self.decision(result), result)
        self.assertEqual(4, len(approver.requests))

    def test_ambiguous_receipt_is_never_success(self) -> None:
        approver = Approver([True])
        runtime = HOOK.HookRuntime(self.root, approver=approver)
        runtime.handle("PreToolUse", self.call)
        runtime.handle("PostToolUse", {**self.call, "tool_response": None})
        receipt = runtime.read_session(self.base)["receipts"][-1]
        self.assertEqual("provider_reported_unknown", receipt["result"])

    def test_local_processing_and_task_ledger_updates_are_allowed(self) -> None:
        runtime = HOOK.HookRuntime(self.root, approver=Approver([]))
        task_ledger = (
            Path.home() / ".closed-dexter" / "execution-state" / "task.json"
        )
        attempts = [
            (
                "mcp__node_repl__js",
                {"code": "nodeRepl.write(2 + 2)"},
            ),
            (
                "functions.exec_command",
                {
                    "cmd": (
                        "python3 scripts/agent-execution-controller.py "
                        f"--state {task_ledger} status"
                    ),
                },
            ),
        ]
        for tool_name, tool_input in attempts:
            with self.subTest(tool_name=tool_name):
                result = runtime.handle(
                    "PreToolUse",
                    {**self.base, "tool_name": tool_name, "tool_input": tool_input},
                )
                self.assertNotEqual("deny", self.decision(result), result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
