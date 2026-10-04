"""Dyno: a local AI safety and alignment research workbench for Apple Silicon."""

from importlib.metadata import PackageNotFoundError, version as _version

# Read from the installed distribution so the CLI reports the release it ships in.
try:
    __version__ = _version("mlx-dyno")
except PackageNotFoundError:  # running from a source checkout without an install
    __version__ = "dev"

__all__ = ["__version__"]
