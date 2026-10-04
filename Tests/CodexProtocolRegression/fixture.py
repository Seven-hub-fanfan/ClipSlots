"""Local JSON-RPC peer. No credentials, network, or user data."""
import json
import os
import sys

mode = sys.argv[1]
log = sys.argv[2]
thread = "fixture-thread"
turn = "fixture-turn"
waiting = {}
projects = {}


def send(value):
    data = (json.dumps(value, ensure_ascii=False) + "\n").encode()
    # Split inside UTF-8 sequences as well as JSON syntax.
    for i in range(0, len(data), 7):
        os.write(1, data[i:i + 7])


def event(method, params):
    send({"method": method, "params": dict(threadId=thread, turnId=turn, **params)})


def completed():
    event("item/reasoning/summaryTextDelta", {"itemId": "summary", "delta": "已查看槽位摘要。"})
    event("item/agentMessage/delta", {"itemId": "answer", "delta": "完成🙂"})
    event("item/completed", {"item": {"id": "answer", "type": "agentMessage", "text": "完成🙂"}})
    event("thread/tokenUsage/updated", {"tokenUsage": {"last": {
        "inputTokens": 100, "outputTokens": 20, "totalTokens": 120, "cachedInputTokens": 50}}})
    event("turn/completed", {"turn": {"id": turn, "status": "completed", "error": None}})


for line in sys.stdin:
    request = json.loads(line)
    with open(log, "a") as output:
        output.write(json.dumps(request, ensure_ascii=False) + "\n")
    method = request.get("method")
    identifier = request.get("id")
    params = request.get("params", {})
    result = {}
    if method == "initialize":
        assert params["capabilities"]["experimentalApi"] is True
        result = {"userAgent": "local-fixture"}
    elif method == "initialized":
        continue
    elif method == "account/read":
        result = {"account": None if mode in ("unauthenticated", "custom") else {"type": "chatgpt", "planType": "plus"},
                  "requiresOpenaiAuth": True}
    elif method == "config/read":
        result = {"config": {"model": "custom-model", "model_provider": "custom" if mode == "custom" else "openai",
                             "model_reasoning_effort": "medium",
                             "mcp_servers": {"external_write": {"command": "/not-executed"}}}}
    elif method == "thread/read":
        result = {"thread": {"id": thread, "name": "桌面会话", "cwd": "/tmp/project",
                             "modelProvider": "custom", "model": "custom-model",
                             "status": {"type": "active" if mode == "busy" else "idle"}}}
        if params.get("includeTurns"):
            result["thread"]["turns"] = [{"items": [{"id": "legacy", "type": "agentMessage", "text": "旧版历史"}]}]
    elif method == "thread/list":
        assert params["modelProviders"] == []
        result = {"data": [{"id": "thread-2" if params.get("cursor") else thread, "cwd": "/tmp/project",
                            "preview": "真实历史", "updatedAt": 123, "status": {"type": "idle"}}],
                  "nextCursor": "page-2" if not params.get("cursor") or mode == "cursor_loop" else None}
    elif method == "project/list":
        if mode == "projects":
            send({"id": identifier, "result": {"data": list(projects.values()), "nextCursor": None}})
            continue
        send({"id": identifier, "error": {"code": -32601, "message": "Method not found"}})
        continue
    elif method == "project/create":
        assert params["idempotencyKey"] and params["roots"][0]["path"].startswith("/")
        projects[params["idempotencyKey"]] = dict(id=params["idempotencyKey"], name=params["name"], roots=params["roots"])
    elif method == "project/update":
        projects[params["projectId"]]["name"] = params["name"]
    elif method == "project/delete":
        del projects[params["projectId"]]
    elif method == "thread/items/list":
        if mode == "legacy":
            send({"id": identifier, "error": {"code": -32601, "message": "Method not found"}})
            continue
        result = {"data": [{"turnId": "t", "item": {"id": "a" if params.get("cursor") else "u",
                    "type": "agentMessage" if params.get("cursor") else "userMessage",
                    "text": "桌面答复", "content": [{"type": "text", "text": "桌面消息"}]}}],
                  "nextCursor": None if params.get("cursor") else "items-2"}
    elif method == "model/list":
        result = {"data": [], "nextCursor": None}
    elif method == "thread/start":
        assert params["sandbox"] == "read-only"
        assert params["approvalPolicy"] == ("on-request" if mode.startswith("interactive_") else "never")
        if mode.startswith("preview_"):
            assert params["dynamicTools"] == []
            assert params["config"]["mcp_servers.clipslots.enabled"] is False
            assert params["config"]["mcp_servers.external_write.enabled"] is False
            assert params["config"]["features.shell_tool"] is False
        else:
            assert params["dynamicTools"][0]["type"] == "function"
        result = {"thread": {"id": thread}}
    elif method == "thread/resume":
        assert params["threadId"] == thread
        assert "dynamicTools" not in params
        result = {"thread": {"id": thread}}
    elif method == "review/start":
        assert params["threadId"] == thread and params["delivery"] == "inline"
        assert params["target"]["type"] == "baseBranch" and params["target"]["branch"] == "main"
        send({"id": identifier, "result": {"reviewThreadId": thread, "turn": {"id": turn, "status": "inProgress"}}})
        event("item/completed", {"item": {"id": "review", "type": "exitedReviewMode", "review": "审查完成：边界条件需要修复"}})
        event("turn/completed", {"turn": {"id": turn, "status": "completed", "error": None}})
        continue
    elif method == "turn/start":
        if mode == "malformed":
            os.write(1, b"{broken-json}\n")
            continue
        if mode == "abrupt":
            sys.exit(0)
        send({"id": identifier, "result": {"turn": {"id": turn, "status": "inProgress"}}})
        if mode == "failure":
            event("turn/completed", {"turn": {"id": turn, "status": "failed",
                                             "error": {"message": "fixture quota exhausted"}}})
        elif mode == "hang":
            continue
        elif mode == "task":
            completed()
        elif mode.startswith("interactive_") or mode == "preview_approval":
            question = mode == "interactive_questions"
            message = {"id": 93, "method": "item/tool/requestUserInput" if question else "item/commandExecution/requestApproval",
                       "params": {"threadId": thread, "turnId": turn, "itemId": "interactive-command",
                                  "command": "echo local-fixture", "cwd": "/tmp", "reason": "测试本次批准",
                                  "questions": [
                                      {"id": "style", "header": "风格", "question": "选择风格", "isOther": False,
                                       "options": [{"label": "自然", "description": "保留自然光"}]},
                                      {"id": "note", "header": "补充", "question": "补充说明", "isOther": True, "isSecret": True}
                                  ]}}
            if mode == "interactive_file":
                message["method"] = "item/fileChange/requestApproval"
                message["params"]["reason"] = "本地文件变更"
            send(message)
            send(message)  # Replay the exact RPC id: never show/execute twice.
            if mode == "interactive_disconnect":
                sys.exit(0)
            if mode == "interactive_finish":
                completed()
        elif mode == "unsupported":
            send({"id": 91, "method": "future/request", "params": {"threadId": thread, "turnId": turn}})
        else:
            send({"id": 92, "method": "item/tool/call", "params": {
                "threadId": thread, "turnId": turn, "callId": "call-1", "tool": "clipslots_tool",
                "arguments": {"tool_name": "disabled_tool" if mode == "denied" else "write_slot" if mode == "slot_write" else "list_slots",
                              "arguments_json": json.dumps({"slot": 1, "text": "Codex 工具联动验证"}) if mode == "slot_write" else "{}"}}})
        continue
    elif method == "turn/interrupt":
        assert params["threadId"] == thread and params["turnId"] == turn
    elif method in ("test/one", "test/two"):
        waiting[method] = identifier
        if len(waiting) == 2:
            send({"id": waiting["test/two"], "result": {"order": 2}})
            send({"id": waiting["test/one"], "result": {"order": 1}})
        continue
    elif method == "test/timeout":
        continue
    elif identifier == 91:
        assert request["error"]["code"] == -32601
        completed()
        continue
    elif identifier == 92:
        assert request["result"]["success"] == (mode not in ("denied", "preview_tools"))
        assert request["result"]["contentItems"][0]["type"] == "inputText"
        completed()
        continue
    elif identifier == 93:
        if mode == "interactive_questions":
            assert request["result"] == {"answers": {"style": {"answers": ["自然"]}, "note": {"answers": ["私密答案"]}}}
        else:
            assert request["result"] == {"decision": "decline" if mode in ("interactive_decline", "preview_approval") else "accept"}
        completed()
        continue
    send({"id": identifier, "result": result})
