# Kanpeki Reader

A manga/comic reader for iOS + macOS. Reads CBZ archives the user already
owns, syncs library and reading position across their devices via iCloud,
and hosts nothing.

Built to replace Kantan, whose problems are the requirements:
no iCloud integration, painful sideloading, no cross-device sync, and a
device wipe costs the entire setup.

**Start here:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — decisions,
rationale, and the phased plan.
[`docs/LIBRARY.md`](docs/LIBRARY.md) — the real library this is built against.

## Status

Phase 0. Nothing built yet. Xcode project not yet created.

## Principles

1. **Host nothing.** Bytes live in the user's iCloud or on their own
   server. Never on infrastructure we control.
2. **Ship empty.** No catalog, no discovery, no scrapers, no in-app
   browser. The user brings their own files.
3. **See nothing.** Reading state lives in the CloudKit *private*
   database, which the developer cannot read. No telemetry carries series
   names or filenames.
4. **The database is a cache.** Anything derived from the files must be
   rebuildable by rescanning them.
