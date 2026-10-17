#!/usr/bin/env python3
"""Private setup and actual HTTP health/probe tests; local providers only."""
import contextlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import urllib.error

import manage
from test_live import ProcessServer, Upstream


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipslots-gateway-setup-test-")
        self.root = Path(self.temporary.name)
        self.config = self.root / "config/gateway.json"

    def tearDown(self):
        self.temporary.cleanup()

    def cli(self, *args, env=None):
        return subprocess.run([sys.executable, "-B", str(Path(manage.__file__)),
                               "--config", str(self.config), *args],
                              capture_output=True, text=True, env=env)

    def initialize(self):
        result = self.cli("init", "--data-dir", str(self.root / "data"))
        self.assertEqual(result.returncode, 0, result.stdout)
        return manage.load(self.config)

    def test_init_private_redacted_and_idempotent(self):
        value = self.initialize()
        before = self.config.read_bytes()
        result = self.cli("init", "--data-dir", str(self.root / "other-data"))
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["created"])
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.config.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / "data").stat().st_mode & 0o777, 0o700)
        self.assertNotIn(value["authToken"], result.stdout + result.stderr)
        self.assertFalse((self.root / "data/state.sqlite").exists())

    def test_missing_provider_refuses_start_and_inherited_key(self):
        self.initialize()
        env = dict(os.environ, GATEWAY_PROVIDER_BASE_URL="https://unused.invalid/v1",
                   GATEWAY_PROVIDER_API_KEY="INHERITED_SECRET_SENTINEL", GATEWAY_PROVIDER_MODEL="unused")
        result = self.cli("start", env=env)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error"], "DEDICATED_PROVIDER_FIELDS_MISSING")
        self.assertNotIn("INHERITED_SECRET_SENTINEL", result.stdout + result.stderr)
        status = json.loads(self.cli("status", env=env).stdout)
        self.assertFalse(status["providerConfigured"])
        self.assertEqual(status["missingProviderFields"], ["baseURL", "apiKey", "model"])

    def test_rejects_public_config_and_symlinks(self):
        self.initialize()
        self.config.chmod(0o644)
        with self.assertRaises(manage.SetupError):
            manage.load(self.config)
        self.config.chmod(0o600)
        link = self.root / "link.json"
        link.symlink_to(self.config)
        with self.assertRaises(OSError):
            manage.load(link)

    def test_configure_requires_interactive_hidden_input(self):
        self.initialize()
        before = self.config.read_bytes()
        result = self.cli("configure")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(json.loads(result.stdout)["error"], "INTERACTIVE_TERMINAL_REQUIRED")

    def test_authenticated_health_no_provider_no_database_mutation(self):
        value = self.initialize()
        server = ProcessServer(synthetic=False, token=value["authToken"])
        try:
            value["port"] = server.port
            health = manage.check(value)
            self.assertFalse(health["providerConfigured"])
            self.assertFalse(health["synthetic"])
            self.assertFalse(health["remoteModelVerified"])
            self.assertTrue(health["authRequired"])
            self.assertEqual(server.http("GET", "health", auth=False)[0], 401)
            self.assertEqual(server.http("GET", "health?unexpected=1")[0], 400)
            self.assertEqual(server.http("POST", "health", {"requestKey": "health"})[0], 404)
            with sqlite3.connect(server.db) as db:
                for table in ("runs", "receipts", "events", "tools"):
                    self.assertEqual(db.execute("SELECT COUNT(*) FROM " + table).fetchone()[0], 0)
        finally:
            server.stop()

    def test_synthetic_health_cannot_be_remote_verification(self):
        value = self.initialize()
        server = ProcessServer(synthetic=True, token=value["authToken"])
        try:
            value["port"] = server.port
            self.assertTrue(manage.check(value)["synthetic"])
            with self.assertRaises(manage.SetupError):
                manage.probe(value)
        finally:
            server.stop()

    def test_health_never_calls_upstream_probe_requires_completion(self):
        value = self.initialize()
        upstream = Upstream()
        server = ProcessServer(synthetic=False, token=value["authToken"], provider=upstream.url)
        try:
            value["port"] = server.port
            value["provider"] = {"baseURL": upstream.url, "apiKey": "synthetic-upstream-key", "model": "test"}
            health = manage.check(value)
            self.assertTrue(health["providerConfigured"])
            self.assertFalse(health["remoteModelVerified"])
            self.assertEqual(len(upstream.requests), 0)
            result = manage.probe(value)
            self.assertTrue(result["providerRequestVerified"])
            self.assertFalse(result["remoteModelVerified"])
            self.assertEqual(result["providerTransport"], "loopback")
            self.assertEqual(result["usage"]["totalTokens"], 5)
            self.assertEqual(len(upstream.requests), 1)
            self.assertNotIn("tools", upstream.requests[0])
        finally:
            server.stop()
            upstream.stop()

    def test_provider_eof_cannot_pass_probe(self):
        value = self.initialize()
        upstream = Upstream("eof")
        server = ProcessServer(synthetic=False, token=value["authToken"], provider=upstream.url)
        try:
            value["port"] = server.port
            value["provider"] = {"baseURL": upstream.url, "apiKey": "synthetic-upstream-key", "model": "test"}
            with self.assertRaisesRegex(manage.SetupError, "PROVIDER_PROBE_INCOMPLETE"):
                manage.probe(value)
        finally:
            server.stop()
            upstream.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
