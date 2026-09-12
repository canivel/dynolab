#!/usr/bin/env python3
"""Apply Dyno's capture patch to a pinned llama.cpp checkout and build its server."""
import argparse
from pathlib import Path
import subprocess
PIN = "5bda51bfbc62e64193221e639f6ad4e08767d760"
p = argparse.ArgumentParser()
p.add_argument("checkout", type=Path)
p.add_argument("--cmake", default="cmake")
p.add_argument("--build-dir", default="build-dyno")
a = p.parse_args()
root = a.checkout.resolve()
patch = Path(__file__).with_name("dyno-capture.patch").resolve()
def run(*cmd): subprocess.run(cmd, cwd=root, check=True)
head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
if head != PIN: raise SystemExit("Checkout must be pinned to " + PIN)
applied = subprocess.run(["git", "apply", "--reverse", "--check", str(patch)], cwd=root, capture_output=True).returncode == 0
if not applied:
    run("git", "apply", "--check", str(patch))
    run("git", "apply", str(patch))
run(a.cmake, "-S", ".", "-B", a.build_dir, "-DGGML_RPC=ON", "-DLLAMA_BUILD_SERVER=ON", "-DCMAKE_BUILD_TYPE=Release")
run(a.cmake, "--build", a.build_dir, "--target", "llama-server", "-j", "8")
print(root / a.build_dir / "bin" / "llama-server")
