# Phase 1 — status and how to finish it

Last updated 2026-09-07.

## What exists

| Step | Component | State |
|---|---|---|
| 1 | `project.yml` → iOS 26 + macOS 26 multiplatform target, iCloud Documents + CloudKit entitlements, app icon | done; iOS sim build + run verified, macOS compiles (`CODE_SIGNING_ALLOWED=NO`) |
| 2 | `UbiquityContainer` creates `<container>/Documents`, `NSUbiquitousContainers` in Info.plist | done; visibility in Files needs a signed-in device |
| 3 | `CloudLibraryMonitor` (`NSMetadataQuery`) + `LocalFolderMonitor` fallback | done; cloud path unverified (no iCloud account on sims) |
| 4 | `DownloadManager` — `startDownloadingUbiquitousItem`, poll-to-ready, `evictUbiquitousItem`, LRU under byte cap, pinning of open archives | done; cap/eviction UI in Storage sheet; eviction itself needs a real container |
| 5 | `ZipArchive` — central directory, Zip64, STORED = mmap slice, DEFLATE via `Compression`, CP932 fallback names, `NaturalSort` page order | done; 9 unit tests incl. DEFLATE + Zip64 |
| 6 | `CloudKitSyncStore` behind `SyncStore` — custom zone, change tokens, newest-wins; `LocalSyncStore` fallback | done; CloudKit path unverified (see blockers) |
| 7 | `LibraryScanner` → SwiftData `VolumeRecord` (local-only), provisional rows for undownloaded files, cover thumbnails; "Rebuild cache" wipes + rescans | done; rebuild proven in tests and on-sim |

Proof reader (`ProofReaderView`) decodes one page via ImageIO thumbnail,
steps pages (RTL-aware buttons), and round-trips the position through
`SyncStore`. It is not the Phase 2 pager.

## Blockers only you can clear

1. ~~Xcode account.~~ Resolved 2026-09-07. Native macOS build:

       xcodebuild -project Kanpeki.xcodeproj -scheme Kanpeki \
         -destination 'platform=macOS' -allowProvisioningUpdates \
         -allowProvisioningDeviceRegistration build

   Verified on the Mac: ubiquity container resolves, files dropped in
   `iCloud Drive/Kanpeki` are enumerated by `NSMetadataQuery`, CloudKit
   zone created, positions written and read back after a cold launch.
2. **iCloud on simulators.** Sign into iCloud in Settings on the
   BookTrove 17 Pro / iPad Air sims (or use real devices). Without it the
   app deliberately falls back to a local folder and a local sync store,
   and says so in the status chip.
3. **Phase 0.** The Claude process is TCC-blocked from
   `~/Library/Mobile Documents`. Grant Full Disk Access (or Files and
   Folders → iCloud Drive) to the Claude app, then:

       ~/Manga/tools/venv/bin/python tools/phase0_comicinfo.py --dry
       ~/Manga/tools/venv/bin/python tools/phase0_comicinfo.py

   Report lands in `tools/phase0_report.log`. Preserves entry order and
   per-entry compression; verifies CRCs before the atomic replace.

## Then the actual Phase 1 acceptance test

1. Mac: drop a `.cbz` into iCloud Drive → Kanpeki.
2. Phone: it appears with a cloud badge; tap → downloads with progress →
   opens → step a few pages.
3. iPad: open the same volume; the "Page N on <device>" banner offers to
   jump there.

## Design notes that came out of building it

- **No automatic eviction on macOS.** First run against the real library
  evicted ~8 GB because the 2 GB LRU cap applied on the Mac. Policy is now
  iOS-only (`DownloadManager.automaticEvictionSupported`). Opening an
  archive pins it *before* it is mapped, and every open re-checks
  `ubiquitousItemDownloadingStatus` instead of trusting the monitor's last
  snapshot, so an evicted file surfaces as "not downloaded" rather than a
  blocking read or an archive with no pages.

- **Provisional IDs.** A file that is not downloaded has no content to
  hash, so its row is keyed `path:<relative path>` until scanned. Such an
  ID is never written to the sync store (you cannot read pages of it
  anyway). `prepare()` upgrades it to the real content hash.
- **Byte-identical archives share a ContentID** and are listed once.
  The real `b` variants differ in content and stay distinct.
- **`com.apple.developer.icloud-container-environment` must be in the
  entitlements** (Development for Debug, Production for Release, via
  `KANPEKI_CLOUDKIT_ENV` in project.yml). Xcode's capability UI injects
  it silently; a generated project does not, and CloudKit then fails with
  "couldn't get container configuration from the server".
- **xcodegen owns the entitlements file.** It regenerates it from
  `project.yml`; an edited file gets overwritten with an empty dict.
- **Simulator entitlements** live in the `__TEXT,__entitlements` section,
  not the ad-hoc signature; `codesign -d --entitlements` shows nothing
  even when they are present.
- CloudKit `refresh()` uses zone change tokens, not queries, so nothing
  in the schema needs a queryable index and it works offline-first.
- Push-driven sync (`CKRecordZoneSubscription` + silent push) is not
  wired; refresh happens on launch, foreground, and manual. Add when the
  aps entitlement is provisioned.
