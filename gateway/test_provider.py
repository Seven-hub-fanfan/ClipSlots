"""Synthetic test model. Imported ONLY by --test-only-provider."""
import json
import time
import uuid


class TestProvider:
    label = "TEST-ONLY-SYNTHETIC-NOT-A-REMOTE-MODEL"

    def generate(self, command, messages, emit, alive):
        emit("note", {"code": "TEST_PROVIDER_SYNTHETIC"})
        last = next((m["content"] for m in reversed(messages) if m["role"] == "user"), "")
        if last == "test:fail":
            raise RuntimeError("test failure")
        fixture_text = next((m["content"] for m in messages if m["role"] == "user"
                             and isinstance(m["content"], str) and m["content"].startswith("test:decision:")), None)
        fixture = json.loads(fixture_text.removeprefix("test:decision:")) if fixture_text else None
        if fixture and (last.startswith("test:decision:") or fixture.get("repeat", False)):
            emit(fixture.get("kind", "waiting_confirmation"),
                 {"interactionID": fixture.get("id", uuid.uuid4().hex),
                  "expiresAt": time.time() + fixture.get("ttl", 300),
                  "params": fixture["params"]})
            return None
        if last == "test:slow":
            emit("content", {"delta": "before-crash"})
            for index in range(400):
                if not alive():
                    return None
                time.sleep(0.05)
                if index == 2:
                    emit("content", {"delta": "after-disconnect"})
        if last == "test:steer-question":
            emit("content", {"delta": "before-wait"})
            for _ in range(100):
                if not alive():
                    return None
                time.sleep(0.01)
        if last in {"test:question", "test:confirmation", "test:steer-question"}:
            emit("waiting_confirmation" if last == "test:confirmation" else "waiting_question",
                 {"interactionID": uuid.uuid4().hex, "expiresAt": time.time() + 300,
                  "params": {"prompt": "Synthetic test interaction",
                             "availableDecisions": ["accept", "decline"],
                             "questions": [{"id": "synthetic-question", "question": "Synthetic test?",
                                            "options": [{"label": "yes", "description": "Test only"}]}]}})
            return None
        if last == "test:metadata":
            emit("artifact_updated", {"artifactID": "test-artifact", "revision": 1,
                                     "path": "test.txt", "content": "synthetic",
                                     "mimeType": "text/plain"})
        if isinstance(last, str) and last.startswith("test:app-artifact:"):
            # Native canvas invocations append their real snapshot context after
            # the leading fixture JSON. Keep that native wire content intact.
            app, _ = json.JSONDecoder().raw_decode(last.removeprefix("test:app-artifact:"))
            emit("artifact_updated", app)
            emit("usage", {"promptTokens": 2, "completionTokens": 3, "totalTokens": 5})
            if app.get("testFile") and messages[-1]["role"] != "tool":
                return {"content": "", "calls": [{"id": "same-call-id", "name": "local_write_file",
                        "argumentsJSON": json.dumps(app["testFile"])}]}
        if last.startswith("test:canvas:"):
            proposal = json.loads(last.removeprefix("test:canvas:"))
            proposal["project_id"] = command["binding"]["projectID"]
            proposal["conversation_id"] = command["binding"]["sessionID"]
            proposal["run_id"] = command["gatewayRunID"]
            # Replay a duplicate notification; confirmation/storage own the
            # mutation receipt and must never apply the graph twice.
            emit("canvas_changed", proposal)
            emit("canvas_changed", proposal)
        if last.startswith("test:tool") and messages[-1]["role"] != "tool":
            count = 2 if last == "test:tool-double" else 1
            return {"content": "", "calls": [
                {"id": "test-call-" + uuid.uuid4().hex, "name": "live_test_tool",
                 "argumentsJSON": '{"text":"synthetic"}'} for _ in range(count)]}
        output = "synthetic-local-http:" + last
        if messages[-1]["role"] == "tool":
            output = "synthetic-tool-result-received"
        emit("thinking", {"delta": "synthetic-reasoning"})
        for part in [output[:12], output[12:]]:
            if not alive():
                return None
            emit("content", {"delta": part})
        return {"content": output, "calls": []}

    def generate_app_reply(self, command, messages, app_reply, emit, alive):
        # Dedicated structured callback. Never converts the reply to a user message.
        emit("note", {"code": "TEST_APP_REPLY_STRUCTURED_CALLBACK",
                      "replyID": app_reply["reply"]["reply_id"]})
        if app_reply["reply"]["payload"].get("slow"):
            for _ in range(400):
                if not alive():
                    return None
                time.sleep(0.01)
        if app_reply["reply"]["payload"].get("fail"):
            raise RuntimeError("synthetic App reply failed")
        if app_reply["reply"]["payload"].get("write_file"):
            return {"content": "", "calls": [{
                "id": app_reply["reply"]["payload"].get("call_id", "same-call-id"),
                "name": "local_write_file",
                "argumentsJSON": json.dumps(app_reply["reply"]["payload"]["write_file"])}]}
        output = "synthetic-structured-app-reply"
        emit("content", {"delta": output})
        return {"content": output, "calls": []}

    def continue_app_reply(self, command, messages, app_reply, emit, alive):
        emit("note", {"code": "TEST_APP_REPLY_CONTINUATION"})
        output = "synthetic-app-reply-continuation"
        emit("content", {"delta": output})
        return {"content": output, "calls": []}
