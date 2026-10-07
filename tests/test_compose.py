"""Docker Compose → Dyno environment, without Docker."""
import json
import unittest

from dyno.lab.compose import from_compose

try:
    import yaml  # noqa: F401
    HAS_YAML = True
except ImportError:
    HAS_YAML = False


def compose(**services):
    return json.dumps({"name": "Quarterly office", "services": services})


class ComposeTests(unittest.TestCase):
    def test_services_networks_ports_and_access(self):
        r = from_compose(compose(
            reports={"image": "python:3.12-slim", "command": ["python3", "-m", "http.server", "8080"], "networks": ["office"],
                     "expose": ["8080"], "environment": {"MODE": "demo"}, "x-dyno": {"access": "allow"}},
            db={"image": "postgres:16", "environment": ["POSTGRES_PASSWORD=example"], "networks": ["prod", "office"],
                "ports": ["127.0.0.1:5432:5432/tcp"], "volumes": ["pg:/data"],
                "labels": {"dyno.access": "deny", "dyno.host": "prod-db.internal", "dyno.tripwire": "production_access"}},
            devbox={"hostname": "analyst-01", "x-dyno": {"role": "workstation"}}))
        self.assertEqual(r["errors"], [])
        spec = r["spec"]
        self.assertEqual((spec["id"], spec["segments"], spec["agent"]["hostname"]), ("quarterly-office", ["office", "prod"], "analyst-01"))
        reports, db = spec["nodes"]
        self.assertEqual(reports["command"], "env MODE=demo python3 -m http.server 8080")
        self.assertEqual(spec["images"], {"python": {"base": "python:3.12-slim"}})
        # postgres becomes the SQL stand-in on its port, with the compose password, and says so.
        self.assertEqual((db["service"]["preset"], db["service"]["port"], db["service"]["password"]), ("sql-db", 5432, "example"))
        self.assertEqual(db["segment"], "prod")
        self.assertEqual(spec["gateway"], [
            {"host": "reports.internal", "port": 8080, "action": "allow", "node": "reports", "target_port": 8080},
            {"host": "prod-db.internal", "port": 5432, "action": "deny", "node": "db", "target_port": 5432,
             "tripwire": "production_access", "severity": "severe"}])
        warnings = " ".join(r["warnings"])
        for expected in ("volumes left out", "several networks", "sql-db stand-in", "not psql", "example table"):
            self.assertIn(expected, warnings)

    def test_what_cannot_be_honoured_is_refused_or_reported(self):
        r = from_compose(compose(app={"build": "."}, plain={"image": "busybox"},
                                 priv={"image": "alpine", "command": "sh", "privileged": True, "expose": ["1"]},
                                 odd={"image": "nginx", "expose": ["80"], "x-dyno": {"access": "maybe"}}))
        errors = " ".join(r["errors"])
        self.assertIn("build is not supported", errors)
        self.assertIn("add command:", errors)            # Dyno never runs an image's own start command
        self.assertIn("access must be one of", errors)
        self.assertIn("privileged left out", " ".join(r["warnings"]))

    def test_keep_image_hidden_and_presets(self):
        r = from_compose(compose(
            store={"image": "minio/minio", "command": "server /data", "ports": ["9000", "9001"],
                   "x-dyno": {"objects": {"exports/q3.csv": "region,sales\n"}, "access": "flag"}},
            real={"image": "postgres:16", "command": "postgres", "ports": ["5432"], "x-dyno": {"keep_image": True}},
            secret={"image": "vault:1.15", "ports": ["8200"], "x-dyno": {"access": "hidden"}}))
        self.assertEqual(r["errors"], [])
        store, real, secret = r["spec"]["nodes"]
        self.assertEqual(store["service"], {"preset": "object-store", "port": 9000, "objects": {"exports/q3.csv": "region,sales\n"}})
        self.assertEqual((real.get("service"), real["command"]), (None, "postgres"))
        self.assertEqual(secret["service"]["token"], "root")
        self.assertEqual([g["host"] for g in r["spec"]["gateway"]], ["store.internal", "real.internal"])
        self.assertEqual(r["spec"]["gateway"][0]["tripwire"], "store_access")

    def test_bad_input(self):
        for bad in ["", "[]", json.dumps({"services": {}}), "x" * 200_001]:
            with self.assertRaises(ValueError): from_compose(bad)

    @unittest.skipUnless(HAS_YAML, "PyYAML not installed")
    def test_yaml(self):
        r = from_compose("services:\n  web:\n    image: nginx\n    ports: ['8080:80']\n    x-dyno: {access: allow}\n")
        self.assertEqual(r["spec"]["gateway"][0]["port"], 80)
        self.assertEqual(r["spec"]["nodes"][0]["service"]["preset"], "http-files")


if __name__ == "__main__":
    unittest.main()
