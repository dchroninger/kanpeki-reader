# Kanpeki Reader

A manga/comic reader for iOS + macOS. Reads CBZ archives the user already
owns, syncs library and reading position across their devices via iCloud,
and hosts nothing.

Built to replace Kantan, whose problems are the requirements:
no iCloud integration, painful sideloading, no cross-device sync, and a
device wipe costs the entire setup.

**Start here:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — decisions,
rationale, and the phased plan.

## Status

Phase 0 done (every archive has ComicInfo.xml, entries named in reading
order). Phase 1 verified end to end on a Mac, iPhone, and the real 10 GB
library in iCloud: enumerate, download on demand, page-curl reader,
positions and a cover/metadata index through CloudKit. See
`docs/PHASE1.md` for what was learned.

## Build

    xcodegen generate            # project.yml is the source of truth
    open Kanpeki.xcodeproj       # scheme: Kanpeki (iOS + macOS)
    (cd KanpekiCore && swift test)

Entitlements are generated from `project.yml` — edit them there, not the
`.entitlements` file.

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
