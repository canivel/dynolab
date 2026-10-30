"""Which past releases get a delta (the macOS-only build steps run in the release workflow)."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("build_deltas", Path(__file__).parents[1] / "scripts/build_deltas.py")
deltas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deltas)


def release(tag, dmg=True, draft=False, prerelease=False):
    version = tag.lstrip("v")
    return {"tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": [{"name": f"Dyno-{version}-arm64.dmg"}] if dmg else [{"name": "SHA256SUMS"}]}


class PreviousReleases(unittest.TestCase):
    def test_newest_published_stable_releases_with_a_dmg(self):
        releases = [release("v0.6.17", draft=True), release("v0.6.16"), release("v0.6.15"), release("v0.6.14"),
                    release("v0.6.13"), release("v0.6.12-beta", prerelease=True), release("v0.6.4", dmg=False)]
        self.assertEqual(deltas.previous_releases("0.6.17", releases, 3), ["0.6.16", "0.6.15", "0.6.14"])

    def test_versions_compare_as_numbers_not_text(self):
        releases = [release("v0.6.9"), release("v0.6.10"), release("v0.6.2")]
        self.assertEqual(deltas.previous_releases("0.6.11", releases, 2), ["0.6.10", "0.6.9"])

    def test_never_from_the_same_or_a_newer_version(self):
        self.assertEqual(deltas.previous_releases("0.6.15", [release("v0.6.15"), release("v0.6.16")], 3), [])


if __name__ == "__main__":
    unittest.main()
