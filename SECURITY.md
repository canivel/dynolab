# Security policy

## Supported versions

Security fixes target the latest published Dyno release and `main`. Older versions may require an upgrade; there is no long-term-support promise for the experimental 0.x series.

## Report privately

Use [GitHub's private vulnerability reporting](https://github.com/canivel/dynolab/security/advisories/new). Include affected version, reproduction steps, impact and a minimal redacted proof of concept. Do not post exploit details, credentials or private prompts in a public issue. Do not test against other people's models or networks.

The maintainer triages reports and coordinates a fix and disclosure. This is a volunteer-maintained project; there is no guaranteed response-time SLA or paid bounty.

## Current boundaries

LAN inference is opt-in and unauthenticated: enable it only on trusted networks. Research and execution endpoints are local-only. Model loading can require third-party repository code when explicitly trusted. Treat models, imported data and MCP-connected assistants according to their access.

Official downloads are GitHub release assets linked from dynolab.dev. Current DMGs are ad-hoc signed and not Apple-notarized. Checksums detect mismatched files but do not replace Developer ID signing. New release workflows produce provenance attestations and draft releases; existing releases do not retroactively gain attestations. See [maintenance](docs/maintaining.md) for verification and the remaining signing work.
