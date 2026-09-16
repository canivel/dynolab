import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

spec = importlib.util.spec_from_file_location("build_appcast", Path(__file__).parents[1] / "scripts/build_appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.archive = Path(self.tmp.name) / "Dyno-0.4.3-arm64.dmg"
        self.archive.write_bytes(b"signed release archive")
        self.key = Ed25519PrivateKey.generate()
        self.public = base64.b64encode(self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
        self.signature = base64.b64encode(self.key.sign(self.archive.read_bytes())).decode()

    def build(self, **changes):
        args = dict(archive=self.archive, version="0.4.3", signature=self.signature,
                    public_key=self.public, notes="Research & updates <reviewed>")
        args.update(changes)
        return appcast.build_appcast(**args)

    def test_verified_release_has_exact_archive_and_escaped_notes(self):
        item = ET.fromstring(self.build()).find("channel/item")
        self.assertEqual(item.findtext("description"), "Research & updates <reviewed>")
        self.assertEqual(item.findtext(f"{{{appcast.SPARKLE}}}version"), "0.4.3")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("length"), str(self.archive.stat().st_size))
        self.assertEqual(enclosure.get("url"), "https://github.com/canivel/dynolab/releases/download/v0.4.3/Dyno-0.4.3-arm64.dmg")

    def test_tampered_archive_is_rejected(self):
        self.archive.write_bytes(b"replaced after signing")
        with self.assertRaises(InvalidSignature): self.build()

    def test_wrong_signing_key_is_rejected(self):
        wrong = base64.b64encode(Ed25519PrivateKey.generate().sign(self.archive.read_bytes())).decode()
        with self.assertRaises(InvalidSignature): self.build(signature=wrong)

    def test_prerelease_or_invalid_version_is_rejected(self):
        for version in ("0.4.3-beta", "latest", "../../other"):
            with self.assertRaises(ValueError): self.build(version=version)

    def test_wrong_artifact_version_is_rejected(self):
        with self.assertRaises(ValueError): self.build(version="0.4.4")

    def test_malformed_signature_is_rejected(self):
        with self.assertRaises(ValueError): self.build(signature="invalid!")
