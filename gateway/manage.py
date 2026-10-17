#!/usr/bin/env python3
"""Private dedicated gateway setup. Never reads App credentials or prints secrets."""
import argparse
import getpass
import json
import os
from pathlib import Path
import secrets
import stat
import sys
import urllib.parse
import urllib.request
import uuid

from server import GatewayError, NoRedirect, OpenAIProvider, decode, encode

DEFAULT = Path.home() / ".config/clipslots-gateway/gateway.json"


class SetupError(Exception):
    pass


def private_directory(path):
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise SetupError("PRIVATE_DIRECTORY_REQUIRED")


def load(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        raise SetupError("CONFIG_NOT_INITIALIZED") from None
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise SetupError("CONFIG_REQUIRES_OWNER_AND_MODE_0600")
        if info.st_size > 65536:
            raise SetupError("CONFIG_TOO_LARGE")
        value = decode(stream.read())
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise SetupError("INVALID_CONFIG_VERSION")
    provider = value.get("provider")
    if not isinstance(provider, dict) or any(not isinstance(provider.get(k), str) for k in ("baseURL", "apiKey", "model")):
        raise SetupError("INVALID_PROVIDER_CONFIG")
    token = value.get("authToken")
    if not isinstance(token, str) or len(token) < 32 or any(ord(c) < 32 or ord(c) >= 127 for c in token):
        raise SetupError("INVALID_LOCAL_TOKEN")
    port = value.get("port")
    if type(port) is not int or not 1 <= port <= 65535:
        raise SetupError("INVALID_PORT")
    db = value.get("database")
    if not isinstance(db, str) or not Path(db).is_absolute():
        raise SetupError("INVALID_DATABASE_PATH")
    if any(provider.values()) and all(provider.get(k) for k in ("baseURL", "apiKey", "model")):
        OpenAIProvider(provider["baseURL"], provider["apiKey"], provider["model"])
    return value


def save_new(path, value):
    private_directory(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def missing(value):
    return [name for name in ("baseURL", "apiKey", "model") if not value["provider"][name].strip()]


def status(path, value):
    return {"schemaVersion": 1, "config": str(path), "configMode": "0600",
            "gatewayURL": f"http://127.0.0.1:{value['port']}/v1",
            "authConfigured": True, "providerConfigured": not missing(value),
            "missingProviderFields": missing(value), "database": value["database"],
            "remoteModelVerified": False}


def request(value, route, body=None):
    url = f"http://127.0.0.1:{value['port']}/v1/" + route
    headers = {"Authorization": "Bearer " + value["authToken"], "Accept": "application/json"}
    if body is not None:
        headers.update({"Content-Type": "application/json", "Idempotency-Key": body["requestKey"]})
    req = urllib.request.Request(url, encode(body).encode() if body is not None else None, headers)
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(req, timeout=35)


def check(value):
    with request(value, "health") as response:
        if response.headers.get_content_type() != "application/json":
            raise SetupError("INVALID_HEALTH_CONTENT_TYPE")
        result = decode(response.read(65537))
    if not isinstance(result, dict) or result.get("schemaVersion") != 1 or result.get("status") != "ok":
        raise SetupError("INVALID_HEALTH_RESPONSE")
    if any(type(result.get(k)) is not bool for k in ("providerConfigured", "synthetic", "authRequired")):
        raise SetupError("INVALID_HEALTH_RESPONSE")
    if not result["authRequired"]:
        raise SetupError("AUTHENTICATED_SERVICE_REQUIRED")
    return dict(result, remoteModelVerified=False)


def probe(value):
    health = check(value)
    if not health["providerConfigured"] or health["synthetic"] or missing(value):
        raise SetupError("DEDICATED_PROVIDER_REQUIRED")
    command = {"schemaVersion": 1, "requestKey": "probe-" + uuid.uuid4().hex,
               "clientInstanceID": "gateway-setup-probe",
               "binding": {"sessionID": "setup-" + uuid.uuid4().hex},
               "config": {"model": value["provider"]["model"], "systemPrompt": "Reply with OK.",
                          "thinkingMode": "serverDefault", "taskPolicy": "textPolish", "maxToolRounds": 0},
               "history": [{"id": str(uuid.uuid4()), "role": "user", "content": "Reply with OK."}],
               "tools": []}
    with request(value, "runs", command) as response:
        receipt = decode(response.read(65537))
    run = receipt.get("runID")
    if not isinstance(run, str) or not run:
        raise SetupError("INVALID_PROBE_RECEIPT")
    event, data, content, assistant, complete, failed, usage = "", [], False, False, False, False, None
    with request(value, "runs/" + urllib.parse.quote(run, safe="") + "/events") as response:
        if response.headers.get_content_type() != "text/event-stream":
            raise SetupError("PROBE_REQUIRES_SSE")
        for _ in range(8192):
            line = response.readline(1_048_577)
            if not line:
                break
            if len(line) > 1_048_576:
                raise SetupError("PROBE_FRAME_TOO_LARGE")
            if line.strip():
                if line.startswith(b"event:"):
                    event = line[6:].strip().decode("utf-8")
                elif line.startswith(b"data:"):
                    data.append(line[5:].strip())
                if sum(map(len, data)) > 1_048_576:
                    raise SetupError("PROBE_FRAME_TOO_LARGE")
                continue
            if data:
                frame = decode(b"\n".join(data))
                if frame.get("runID") != run or frame.get("binding") != command["binding"]:
                    raise SetupError("PROBE_BINDING_MISMATCH")
                payload = frame.get("payload", {})
                content |= event == "content" and bool(payload.get("delta"))
                assistant |= event == "assistant_completed"
                complete |= event == "run_completed"
                failed |= event in {"run_failed", "run_cancelled", "client_tool_request"}
                if event == "usage":
                    usage = {k: payload.get(k) for k in ("promptTokens", "completionTokens", "totalTokens")}
            event, data = "", []
    if not content or not assistant or not complete or failed:
        raise SetupError("PROVIDER_PROBE_INCOMPLETE")
    remote = urllib.parse.urlsplit(value["provider"]["baseURL"]).hostname != "127.0.0.1"
    return {"schemaVersion": 1, "remoteModelVerified": remote, "providerRequestVerified": True,
            "providerTransport": "remoteHTTPS" if remote else "loopback", "synthetic": False,
            "scope": "one explicit text-only HTTP/SSE request; no tools or media generation", "usage": usage}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT)
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init", help="Create 0600 config with a new local token, no provider credentials")
    init.add_argument("--port", type=int, default=8787)
    init.add_argument("--data-dir", type=Path, default=Path.home() / ".local/share/clipslots-gateway")
    sub.add_parser("status", help="Redacted local readiness; does not call a network")
    sub.add_parser("configure", help="Interactive dedicated provider setup; key input is hidden")
    start = sub.add_parser("start", help="Start foreground gateway using only this explicit config")
    start.add_argument("--allow-unconfigured", action="store_true", help="Allow health check only; run creation still fails")
    sub.add_parser("check", help="Authenticated read-only health; does not call a model")
    sub.add_parser("probe", help="Explicit one-request text-only end-to-end model verification")
    args = parser.parse_args()
    path = args.config.expanduser().absolute()
    os.umask(0o077)
    if args.command == "init":
        if path.exists() or path.is_symlink():
            value = load(path)
            result = dict(status(path, value), created=False)
        else:
            if not 1 <= args.port <= 65535:
                raise SetupError("INVALID_PORT")
            data = args.data_dir.expanduser().absolute()
            private_directory(data)
            value = {"schemaVersion": 1, "port": args.port, "database": str(data / "state.sqlite"),
                     "authToken": secrets.token_urlsafe(48),
                     "provider": {"baseURL": "", "apiKey": "", "model": ""}}
            save_new(path, value)
            result = dict(status(path, value), created=True)
    else:
        value = load(path)
        if args.command == "configure":
            if not sys.stdin.isatty():
                raise SetupError("INTERACTIVE_TERMINAL_REQUIRED")
            provider = {"baseURL": input("Dedicated API base URL: ").strip(),
                        "model": input("Dedicated model: ").strip(),
                        "apiKey": getpass.getpass("Dedicated provider key (hidden): ").strip()}
            if not all(provider.values()):
                raise SetupError("ALL_THREE_PROVIDER_FIELDS_REQUIRED")
            OpenAIProvider(provider["baseURL"], provider["apiKey"], provider["model"])
            value["provider"] = provider
            temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
            save_new(temporary, value)
            os.replace(temporary, path)
            result = dict(status(path, value), saved=True)
        elif args.command == "status":
            result = status(path, value)
        elif args.command == "check":
            result = check(value)
        elif args.command == "probe":
            result = probe(value)
        else:
            if missing(value) and not args.allow_unconfigured:
                raise SetupError("DEDICATED_PROVIDER_FIELDS_MISSING")
            private_directory(Path(value["database"]).parent)
            # Clear inherited gateway values, then use only the explicit private file.
            env = {k: v for k, v in os.environ.items() if not k.startswith("GATEWAY_")}
            env["GATEWAY_AUTH_TOKEN"] = value["authToken"]
            if not missing(value):
                for key, field in [("BASE_URL", "baseURL"), ("API_KEY", "apiKey"), ("MODEL", "model")]:
                    env["GATEWAY_PROVIDER_" + key] = value["provider"][field]
            os.execve(sys.executable, [sys.executable, "-B", str(Path(__file__).with_name("server.py")),
                                      "--port", str(value["port"]), "--db", value["database"]], env)
    print(encode(result))


if __name__ == "__main__":
    try:
        main()
    except (SetupError, GatewayError) as error:
        print(encode({"ok": False, "error": str(error) if isinstance(error, SetupError) else error.code}))
        sys.exit(2)
    except Exception:
        # HTTP bodies, URL exceptions and OS arguments can contain credentials.
        print(encode({"ok": False, "error": "SETUP_OR_CONNECTION_FAILED"}))
        sys.exit(2)
