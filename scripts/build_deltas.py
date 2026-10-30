"""Sparkle delta updates: the new app as a patch against each of the last few releases.

The DMG is ~300 MB because it carries Python and its libraries, which rarely change; a delta from the previous
release is a few MB. For each recent stable release this downloads its DMG, checks the app inside is ours
(Developer ID, our team), makes a delta with Sparkle's BinaryDelta, applies it to prove it rebuilds the new app
exactly, and signs it with the Sparkle key. A release a delta can't be made from is skipped: Sparkle then
downloads the full DMG, as it always has. A delta that doesn't verify is never written.

usage: build_deltas.py NEW_DMG VERSION --sparkle-bin DIR --out DIR [--count 3] [--team-id ID]
The Sparkle private key is read from $SPARKLE_PRIVATE_KEY. Writes <out>/Dyno-<version>-from-<old>.delta and
<out>/deltas.json ([{"from", "file", "length", "signature"}]) for build_appcast.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from contextlib import contextmanager
from pathlib import Path

REPO = "canivel/dynolab"
STABLE = re.compile(r"v(\d+)\.(\d+)\.(\d+)")


def key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def previous_releases(version: str, releases: list[dict], count: int) -> list[str]:
    """The newest `count` published stable versions older than `version` that have a DMG."""
    found = []
    for release in releases:
        match = STABLE.fullmatch(release.get("tag_name") or "")
        if not match or release.get("draft") or release.get("prerelease"): continue
        old = ".".join(match.groups())
        if key(old) >= key(version): continue
        if any(a.get("name") == f"Dyno-{old}-arm64.dmg" for a in release.get("assets") or []):
            found.append(old)
    return sorted(found, key=key, reverse=True)[:count]


def releases_from_github() -> list[dict]:
    request = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases?per_page=30",
                                     headers={"Accept": "application/vnd.github+json"})
    if token := os.environ.get("GH_TOKEN"): request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def run(*args: str, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


@contextmanager
def mounted(dmg: Path):
    out = run("hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", str(dmg)).stdout
    points = re.findall(r"<key>mount-point</key>\s*<string>([^<]+)</string>", out)
    if not points: raise RuntimeError(f"{dmg.name}: no volume mounted")
    try: yield Path(points[0])
    finally: subprocess.run(["hdiutil", "detach", "-quiet", points[0]], check=False)


def copy_app(dmg: Path, into: Path) -> Path:
    with mounted(dmg) as volume:
        app = into / "Dyno.app"
        run("ditto", str(volume / "Dyno.app"), str(app))
    return app


def check_ours(app: Path, team_id: str) -> None:
    """An app from a past release must be one we signed before we diff against it."""
    run("codesign", "--verify", "--deep", "--strict", str(app))
    details = run("codesign", "-dvv", str(app)).stderr
    if f"TeamIdentifier={team_id}" not in details or "Authority=Developer ID Application" not in details:
        raise RuntimeError(f"{app}: not signed with our Developer ID ({team_id})")


def same_tree(a: Path, b: Path) -> bool:
    # BinaryDelta preserves files, symlinks and permissions; diff compares contents and lists missing files.
    return subprocess.run(["diff", "-rq", "--no-dereference", str(a), str(b)], capture_output=True).returncode == 0


def make_delta(old_app: Path, new_app: Path, delta: Path, sparkle_bin: Path, work: Path) -> None:
    binary_delta = str(sparkle_bin / "BinaryDelta")
    run(binary_delta, "create", str(old_app), str(new_app), str(delta))
    rebuilt = work / "rebuilt.app"
    run(binary_delta, "apply", str(old_app), str(rebuilt), str(delta))
    if not same_tree(rebuilt, new_app):
        raise RuntimeError(f"{delta.name} does not rebuild the new app exactly")
    run("codesign", "--verify", "--deep", "--strict", str(rebuilt))


def sign(path: Path, sparkle_bin: Path, private_key: str) -> str:
    out = run(str(sparkle_bin / "sign_update"), "--ed-key-file", "-", "-p", str(path), input=private_key).stdout
    return out.strip()


def build(new_dmg: Path, version: str, sparkle_bin: Path, out: Path, count: int, team_id: str,
          private_key: str, releases: list[dict], download=None) -> list[dict]:
    download = download or (lambda old, to: urllib.request.urlretrieve(
        f"https://github.com/{REPO}/releases/download/v{old}/Dyno-{old}-arm64.dmg", to))
    made = []
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "new").mkdir()
        new_app = copy_app(new_dmg, tmp / "new")
        for old in previous_releases(version, releases, count):
            work = tmp / old
            work.mkdir()
            delta = out / f"Dyno-{version}-from-{old}.delta"
            try:
                dmg = work / f"Dyno-{old}-arm64.dmg"
                download(old, dmg)
                old_app = copy_app(dmg, work)
                check_ours(old_app, team_id)
                make_delta(old_app, new_app, delta, sparkle_bin, work)
            except Exception as error:  # noqa: BLE001 - one bad old release must not block the others
                delta.unlink(missing_ok=True)
                print(f"No delta from {old}: {error}", file=sys.stderr)
                continue
            made.append({"from": old, "file": delta.name, "length": delta.stat().st_size,
                         "signature": sign(delta, sparkle_bin, private_key)})
            print(f"Delta from {old}: {delta.stat().st_size / 1e6:.1f} MB")
    (out / "deltas.json").write_text(json.dumps(made, indent=2) + "\n")
    return made


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("new_dmg", type=Path)
    parser.add_argument("version")
    parser.add_argument("--sparkle-bin", type=Path, required=True, help="Sparkle's bin folder (BinaryDelta, sign_update)")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--count", type=int, default=3)
    parser.add_argument("--team-id", default=os.environ.get("APPLE_TEAM_ID", "G25MV42MRK"))
    args = parser.parse_args()
    private_key = os.environ.get("SPARKLE_PRIVATE_KEY") or sys.exit("SPARKLE_PRIVATE_KEY is not set")
    build(args.new_dmg, args.version, args.sparkle_bin, args.out, args.count, args.team_id, private_key,
          releases_from_github())
