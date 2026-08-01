#!/usr/bin/env python3
import json
import sys


submitted = None


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


for raw_line in sys.stdin:
    message = json.loads(raw_line)
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params", {})

    if method == "initialize":
        # Bidirectional JSON-RPC peers own independent id spaces. This request
        # deliberately collides with the client's id and must not be mistaken
        # for the initialize response.
        send({"id": request_id, "method": "guardian/testRequest", "params": {}})
        send({"id": request_id, "result": {"userAgent": "gate0-fixture"}})
    elif method == "initialized":
        continue
    elif method == "thread/resume":
        send({
            "id": request_id,
            "result": {"thread": {"id": params["threadId"], "turns": []}},
        })
    elif method == "thread/read":
        turns = []
        if submitted is not None:
            turns = [{
                "id": "turn-fixture",
                "items": [{
                    "type": "userMessage",
                    "id": "item-fixture",
                    "clientId": submitted["client_id"],
                }],
            }]
        send({
            "id": request_id,
            "result": {"thread": {"id": params["threadId"], "turns": turns}},
        })
    elif method == "turn/start":
        submitted = {
            "thread_id": params["threadId"],
            "client_id": params["clientUserMessageId"],
        }
        send({
            "id": request_id,
            "result": {
                "turn": {"id": "turn-fixture", "status": "inProgress", "items": []}
            },
        })
        send({
            "method": "turn/completed",
            "params": {
                "threadId": params["threadId"],
                "turn": {"id": "turn-fixture", "status": "completed", "items": []},
            },
        })
