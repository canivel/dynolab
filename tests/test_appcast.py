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
        self.assertEqual(item.findtext("description"), "<p>Research &amp; updates &lt;reviewed&gt;</p>")
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


class DeltaTests(unittest.TestCase):
    """Delta enclosures: listed per old version, signed with the app's key, named for their versions."""
    setUp = AppcastTests.setUp
    build = AppcastTests.build

    def add_delta(self, old, data=b"patch", signer=None):
        path = Path(self.tmp.name) / f"Dyno-0.4.3-from-{old}.delta"
        path.write_bytes(data)
        signature = base64.b64encode((signer or self.key).sign(data)).decode()
        return {"from": old, "file": path.name, "length": len(data), "signature": signature}

    def test_deltas_are_listed_with_their_old_version(self):
        deltas = [self.add_delta("0.4.2"), self.add_delta("0.4.1", b"bigger patch")]
        item = ET.fromstring(self.build(deltas=deltas)).find("channel/item")
        enclosures = item.findall(f"{{{appcast.SPARKLE}}}deltas/enclosure")
        self.assertEqual([e.get(f"{{{appcast.SPARKLE}}}deltaFrom") for e in enclosures], ["0.4.2", "0.4.1"])
        self.assertEqual(enclosures[1].get("url"), "https://github.com/canivel/dynolab/releases/download/v0.4.3/Dyno-0.4.3-from-0.4.1.delta")
        self.assertEqual(enclosures[1].get("length"), str(len(b"bigger patch")))
        self.assertEqual(enclosures[0].get(f"{{{appcast.SPARKLE}}}version"), "0.4.3")
        self.assertEqual(item.find("enclosure").get("url").rsplit("/", 1)[1], "Dyno-0.4.3-arm64.dmg")  # the full archive stays

    def test_no_deltas_no_deltas_element(self):
        self.assertIsNone(ET.fromstring(self.build()).find(f"channel/item/{{{appcast.SPARKLE}}}deltas"))

    def test_a_delta_signed_with_another_key_is_rejected(self):
        with self.assertRaises(InvalidSignature): self.build(deltas=[self.add_delta("0.4.2", signer=Ed25519PrivateKey.generate())])

    def test_a_delta_changed_after_signing_is_rejected(self):
        delta = self.add_delta("0.4.2")
        (Path(self.tmp.name) / delta["file"]).write_bytes(b"swapped")
        with self.assertRaises(InvalidSignature): self.build(deltas=[delta])

    def test_a_delta_for_another_version_is_rejected(self):
        delta = self.add_delta("0.4.2")
        for bad in ({**delta, "from": "0.4.2-beta"}, {**delta, "file": "Dyno-0.4.4-from-0.4.2.delta"}):
            with self.assertRaises(ValueError): self.build(deltas=[bad])


class ReleaseNotesTests(unittest.TestCase):
    def test_only_current_release_is_rendered_as_html(self):
        notes = "# Dyno Lab 0.5.1\n\n- **New** [guide](agent-sandbox-tests.md) and [site](https://dynolab.dev)\n\n---\n\nDyno Lab 0.5.0 older notes"
        html = appcast.release_notes_html(notes, "0.5.1")
        self.assertIn("<h1>Dyno Lab 0.5.1</h1>", html)
        self.assertIn("<strong>New</strong>", html)
        self.assertIn('href="https://github.com/canivel/dynolab/blob/v0.5.1/docs/agent-sandbox-tests.md"', html)
        self.assertIn('href="https://dynolab.dev"', html)
        self.assertNotIn("older notes", html)
