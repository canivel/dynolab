# Unreleased

Changes merged to `main` since the last release. Each PR adds its line here, under the heading for the part of Dyno it changes, written for the people who use Dyno. At release time this file becomes the new `release-notes.md`, and is reset to this header.

## Updates

- **Smaller updates.** Updating from one of the last three releases now downloads a delta of about 5 MB instead of the whole 306 MB DMG: only what changed in the app, while Python and its libraries stay as they are. Each delta is checked to rebuild the new app exactly before it's published, and is signed like the DMG. If one can't be used, the updater downloads the full DMG as before.

## Router

- **An idle router no longer runs hot.** With **Scan** on and no model server answering, the router could find itself among the ports it scans and keep sending requests to itself, using about a fifth of a CPU core indefinitely and filling its log with errors. It now skips its own port and other routers, and reuses an empty result for a few seconds instead of scanning on every poll.

