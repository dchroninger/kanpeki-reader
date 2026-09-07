# Architecture & Plan

Status: pre-implementation. Decisions below are settled unless marked OPEN.

---

## 1. The problem, stated correctly

This is not a rendering project. Rendering a CBZ is a weekend; the format
is a ZIP of images and nothing else. Every complaint driving this build is
a **sync** problem:

| Kantan pain | Real requirement |
|---|---|
| No iCloud tie-in | Library lives in the user's own cloud storage |
| Painful uploading | Drop a file in a folder, it appears on every device |
| No cross-device sync | Reading position follows the user |
| Wipe = total loss | Full restore with no user action beyond signing in |
| No sign-in | Identity without building auth |

So: **build a sync layer that happens to render pages.**

---

## 2. Core decision — split bulk from state

These have opposite characteristics and must never share a system.

| | Contents | Size | Mutability | Home |
|---|---|---|---|---|
| **Bulk** | page images | ~10 GB | write-once | iCloud Drive (ubiquity container) |
| **State** | reading position, collections, marks | KB | changes every page turn | CloudKit private DB |

Consequences:

- CloudKit private DB gives **free identity** (Apple ID), so we build zero
  auth, and **free restore** after a wipe.
- It is charged against the *user's* quota, not ours. State is kilobytes.
- The developer **cannot read** the private database. That is an
  architectural fact, not a policy promise — it is the backbone of the
  content-neutrality posture.
- **Never** store reading position as sidecar files next to the archives.
  Per-page-turn file writes produce conflict files and terrible latency.

---

## 3. Storage layout

Library root is the app's **iCloud ubiquity container**, surfaced in Files
with the app icon:

```xml
<key>NSUbiquitousContainers</key>
<dict>
  <key>iCloud.com.dchroninger.kanpeki</key>
  <dict>
    <key>NSUbiquitousContainerIsDocumentScopePublic</key><true/>
    <key>NSUbiquitousContainerName</key><string>Kanpeki</string>
    <key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
  </dict>
</dict>
```

`SupportedFolderLevels: Any` preserves the `<language>/<series>/` hierarchy.

The existing library is **moved, not copied** — a copy is another 10 GB
against the same quota for zero benefit.

iOS cannot hold 10 GB locally. Required:
- `startDownloadingUbiquitousItem` on open, with real "not downloaded" UI
- `evictUbiquitousItem` under an LRU byte cap — **iOS/iPadOS only.** The
  Mac holds the whole library; automatic eviction there threw 8 GB off the
  disk on first run (2026-09-07). iCloud Drive's own "Optimize Mac
  Storage" governs the Mac; the app only evicts on explicit request.
- `NSMetadataQuery` to observe the folder, `NSFileCoordinator` for access

**The eviction policy is the hard part and most of what separates this
from Kantan.** Budget for it.

---

## 4. Two protocols to define on day one

Both exist to contain a known one-way door. Write them before the
implementations.

### `LibrarySource`
Where archives come from. The renderer must never learn the answer.

```
listSeries() / listVolumes(series:) / pageData(volume:index:) / pageCount(volume:)
```

- `CloudLibrarySource` — Phase 1
- `OPDSLibrarySource` — Phase 3

These are **not** alternatives; they serve different users. iCloud is for
someone with a pile of files. OPDS is for someone already running
Komga/Kavita/Calibre-Web who wants a better reader against it.

### `SyncStore`
Where reading state lives.

```
progress(for: ContentID) / setProgress(_:for:) / observeChanges()
```

- `CloudKitSyncStore` — Phase 1

CloudKit is iOS/macOS forever. If Android is ever plausible, this protocol
is the difference between a contained swap and a rewrite. Do not scatter
`CKRecord` through the view layer.

---

## 5. Archive handling

**Fast path: 152 of 159 archives are STORED (uncompressed)**, built with
`zip -0`. For those, page extraction is a byte-range read at a known
offset — no decompression. `mmap` the file and hand
`CGImageSourceCreateWithDataProvider` a subrange.

**7 archives use DEFLATE** (see LIBRARY.md). Treat STORED as an
optimisation, never an assumption. Keep producing STORED for archives we
build ourselves.

Requirements for the ZIP reader:
- Parse the central directory once; cache entry names + offsets + methods
- Random access by entry. **Never extract a whole archive.**
- Fast path: STORED → direct mmap subrange
- Must still handle DEFLATE, since imported archives from elsewhere will
  use it
- Page order = entries sorted by filename, natural/version sort.
  **That sort *is* the format.** Mixed zero-padding otherwise scrambles
  pages — this bit us repeatedly building the library.

### Decode
Never decode at full size. 200 pages x ~4 MB decoded is an instant OOM.

- `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceThumbnailMaxPixelSize` = screen pixel width
- `kCGImageSourceCreateThumbnailFromImageAlways: true`
- Prefetch window of +/-2 pages
- Cache decoded bitmaps against a strict **byte** budget, not object count

---

## 6. Reading behaviour

- **Right-to-left paging is mandatory.** This library is Japanese. Driven
  by `ComicInfo.xml` `<Manga>YesAndRightToLeft</Manga>`, not guessed.
- **Spread pages — decide per page, at display time.** Two distinct cases:
  three volumes are *entirely* two-page spreads, and several normal volumes
  contain occasional double-page artwork. Conflating them causes bugs, so
  `DoublePage` is a per-page attribute and layout is a per-page decision.
  A wide page must fit-width or offer auto-landscape, never be squeezed.
  **Never infer page geometry from the cover** — in the spread-format
  volumes the cover is a normal portrait page while every interior is wide.
- Cover is page 0 and is marked `Type="FrontCover"`.

### Pager implementation
Use a UIKit `UICollectionView` with horizontal paging, wrapped in
`UIViewControllerRepresentable`. SwiftUI's pager has memory and recycling
behaviour that does not hold up over a 200-page volume with large images.
This is a deliberate exception to an otherwise SwiftUI app.

---

## 7. Metadata model — three independent layers

**Layer 1 — the archive.** A ZIP of images. No inherent metadata, no order
field, no title. Order is filename sort. That is the whole spec.

**Layer 2 — embedded `ComicInfo.xml`.** One XML file at the archive root.
De-facto standard (ComicRack heritage; read by Komga, Kavita, ComicRack).
Readers that don't understand it skip it.

```xml
<?xml version="1.0"?>
<ComicInfo>
  <Series>月夜の物語</Series>
  <Number>1</Number>
  <LanguageISO>ja</LanguageISO>
  <Manga>YesAndRightToLeft</Manga>
  <PageCount>197</PageCount>
  <Pages>
    <Page Image="0" Type="FrontCover"/>
    <Page Image="1" DoublePage="true"/>
  </Pages>
</ComicInfo>
```

Writing this also makes the library portable to Komga/Kavita — insurance
against this app never shipping.

**Layer 3 — the library database (derived).** The scanner:

1. Walk the tree, find archives
2. Read `ComicInfo.xml` if present; **else infer** from filename/folder
3. Compute a stable `ContentID` — hash of the ZIP central directory
4. Record series, number, page count, page index (names + offsets)
5. Decode and cache a cover thumbnail
6. Persist to SwiftData (**local-only store — this is a cache, not synced**)
7. Watch for changes, rescan incrementally

**`ContentID` must be content-derived, never the file URL.** Moving or
renaming a file must not lose the user's place.

The filename fallback already works on the existing library: every file is
`<series><fullwidth-number>.cbz`, so a regex recovers series and volume
with no metadata at all.

---

## 8. Content-neutrality posture

Not legal advice. These are the architectural decisions that support it.

- **Host nothing, proxy nothing.** No bytes traverse infrastructure we
  control. DMCA safe harbour is a framework for hosts; storing nothing
  puts us largely outside that regime rather than relying on an exemption
  within it.
- **Ship empty.** No catalog, no source list, no scraper, no in-app
  browser. This is the line App Review draws between a reader and a piracy
  tool. Aidoku and Paperback ship sourceless deliberately.
- **No identifying telemetry.** No series names or filenames leave the
  device. Scrub paths from crash reports. OPDS credentials go in Keychain
  and are transmitted only to the user's own server.
- **Rate honestly.** An app displaying arbitrary user content generally
  needs a high age rating. Relevant guidelines: 1.1.x objectionable
  content, 1.2 UGC, 5.2 IP.
- **Give the reviewer something to review.** An empty app with no obvious
  way in gets rejected as non-functional. Ship a small public-domain
  sample, or a first-run flow that walks through adding a folder.

Precedent for the category: VLC, Infuse, Documents by Readdle.

---

## 9. Phased plan

### Phase 0 — metadata (no code)
Generate `ComicInfo.xml` into all 159 archives. Pure upside: needed by
this app, and makes the library work in Komga/Kavita regardless.
Must preserve archive entry order (technique already proven — see
`~/Manga/tools/apply.py`).

### Phase 1 — iCloud, and nothing else  <-- CURRENT GOAL
Prove the plumbing before building a product on it.

1. Xcode project, iOS + macOS targets, CloudKit + iCloud Documents
   entitlements
2. Ubiquity container configured and visible in Files with the app icon
3. Enumerate the container with `NSMetadataQuery` (library move is a
   separate user action — see section 10)
4. On-demand download with progress UI; LRU eviction under a byte cap
5. ZIP central-directory reader; list pages without extracting
6. `CloudKitSyncStore` behind `SyncStore`: write a position on one device,
   read it on another
7. Scanner producing the SwiftData cache; prove it rebuilds from scratch

**Done when:** a file dropped on the Mac appears on the phone, opens,
remembers its page, and that page is visible on the iPad.

### Phase 2 — the reader
Pager, RTL, spread handling, decode pipeline, thumbnails, library UI.

### Phase 3 — OPDS
`OPDSLibrarySource`. Feeds 1.x (XML) and 2.0 (JSON), HTTP Basic auth,
pagination, search, and **OPDS-PSE** for page streaming — without PSE a
client must download a whole 50-100 MB volume before page 1.

---

## 10. Open questions

Resolved 2026-09-07:

- **Minimum OS: iOS 26 / macOS 26.** Drops only 2018 iPhones (XS/XR) and
  iPad 7th gen. iOS 27 ships Sept 2026, so by Phase 2 this is the usual
  current+previous policy. Buys unconditional Liquid Glass and stable
  SwiftData with no `#available` forks.
- **macOS: native SwiftUI target**, not Catalyst, not iPad-on-Mac. Same
  code; AppKit host; ubiquity + `NSMetadataQuery` behave identically.
- **ZIP reader: hand-rolled.** Central-directory parser, STORED = mmap
  subrange, DEFLATE via `Compression` (zlib raw). No dependency.
  Tested against the 7 DEFLATE archives in LIBRARY.md.
- **Phase 0 runs before the scanner**, in place, order-preserving,
  verified per archive before atomic replace. Original compression method
  per entry is preserved so LIBRARY.md's STORED/DEFLATE facts stay true.

Still OPEN:

- Does the app write `ComicInfo.xml` for imported archives lacking it, or
  keep imports read-only?
- Local cover thumbnail cache location and eviction — separate budget
  from page cache?
- Moving the existing library from `com~apple~CloudDocs/Manga` into the
  app container is a user action (10 GB re-index); Phase 1 is proven with
  files the user drops in, then the move happens once.
