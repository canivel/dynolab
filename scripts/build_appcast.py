"""Build a release feed only after verifying the final DMG's Ed25519 signature."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def build_appcast(archive, version, signature, public_key, notes):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("The stable updater requires a three-part release version")
    archive = Path(archive)
    if archive.name != f"Dyno-{version}-arm64.dmg":
        raise ValueError("Archive filename does not match the release version")
    # Verify against the public key shipped in the app, not merely the CI key.
    key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key, validate=True))
    key.verify(base64.b64decode(signature, validate=True), archive.read_bytes())
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Dyno Lab updates"
    ET.SubElement(channel, "link").text = "https://dynolab.dev"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Dyno Lab {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
    ET.SubElement(item, "description").text = notes
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/canivel/dynolab/releases/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size), "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("version")
    parser.add_argument("--signature", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, default=Path("app/sparkle-public-key.txt"))
    parser.add_argument("--notes", type=Path, default=Path("docs/release-notes.md"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_bytes(build_appcast(args.archive, args.version,
        args.signature.read_text().strip(), args.public_key.read_text().strip(), args.notes.read_text()))
