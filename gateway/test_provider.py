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
        if last == "test:slow":
            emit("content", {"delta": "before-crash"})
            for index in range(400):
                if not alive():
                    return None
                time.sleep(0.05)
                if index == 2:
                    emit("content", {"delta": "after-disconnect"})
        if last in {"test:question", "test:confirmation"}:
            emit("waiting_question" if last == "test:question" else "waiting_confirmation",
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
            emit("usage", {"promptTokens": 2, "completionTokens": 3, "totalTokens": 5})
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
