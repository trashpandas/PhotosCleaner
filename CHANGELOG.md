# PhotosCleaner — Changelog

All notable changes to the PhotosCleaner macOS application are documented in this file.
The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

Developed by **Claude Opus 4.6** and **Richard Henderson**.

---

## [2.0.0] — 2026-03-07

### Summary

A major feature release that transforms PhotosCleaner from a simple screenshot/junk detector
into a comprehensive photo library analysis tool. Version 2.0 adds EXIF metadata extraction,
perceptual duplicate detection via Apple's Vision framework, automatic source classification
(camera vs. web-saved vs. screenshot), content categorization, a tabbed results dashboard,
a dedicated duplicate review interface, GPS-based location grouping with reverse geocoding,
and a brand-new professional skeuomorphic application icon.

### Added — EXIF Metadata Extraction (`EXIFExtractor.swift`)

- **New file: `EXIFExtractor.swift`** — a standalone service class for reading EXIF metadata
  from Photos library assets without decoding the full pixel buffer.
- Extracts camera manufacturer (`Make`), camera model (`Model`), lens description (`LensModel`),
  and the original capture timestamp (`DateTimeOriginal`) from each photo's TIFF and EXIF
  dictionaries via `CGImageSourceCopyPropertiesAtIndex`.
- Extracts GPS coordinates (latitude, longitude) with proper hemisphere handling (N/S for
  latitude, E/W for longitude reference) from the GPS dictionary.
- Performs reverse geocoding of GPS coordinates via `CLGeocoder` to produce human-readable
  location names in "City, Region" format.
- Uses `PHContentEditingInputRequestOptions` with `isNetworkAccessAllowed = false` to read
  the `fullSizeImageURL` for each asset, then creates a `CGImageSource` to read properties
  at index 0 — this avoids loading the full image into memory.
- Source classification logic: determines whether each photo was taken by a camera (has EXIF
  Make/Model), is a screenshot (`PHAssetMediaSubtype.photoScreenshot`), a panorama
  (`.photoPanorama`), an HDR photo (`.photoHDR`), a Live Photo (`.photoLive`), a depth-effect
  photo (`.photoDepthEffect`), or a web/saved image (no camera EXIF data and no special
  media subtype).
- All methods are `static` and thread-safe for concurrent invocation from the scan pipeline.

### Added — Perceptual Duplicate Detection (`DuplicateDetector.swift`)

- **New file: `DuplicateDetector.swift`** — uses Apple's Vision framework to generate
  perceptual fingerprints and identify visually similar or duplicate photos.
- `generateFingerprint(for:imageManager:completion:)` requests a 512×512 thumbnail from
  `PHImageManager`, then runs a `VNGenerateImageFeaturePrintRequest` on a background queue
  to produce a `VNFeaturePrintObservation` for each photo.
- Uses `.highQualityFormat` delivery mode and skips degraded placeholder images to ensure
  fingerprints are generated from actual photo data, not low-res thumbnails.
- `findDuplicateGroups(items:fingerprints:)` performs O(n²) pairwise comparison of all
  fingerprints using `VNFeaturePrintObservation.computeDistance(to:)`. Photos with a
  feature-print distance below the configurable threshold (default: 0.5) are grouped together.
- Groups are built greedily: for each unassigned item, all unassigned items within the
  distance threshold are collected into the same group. Only groups with 2 or more items
  are returned.
- Fingerprints are stored in-memory as `VNFeaturePrintObservation` objects (not serialized
  to `Data`) for efficient comparison.

### Added — Content Categorization (`CategoryAnalyzer.swift`)

- **New file: `CategoryAnalyzer.swift`** — assigns high-level content categories to every
  photo based on metadata analysis (no machine learning required).
- Priority-based categorization: screenshot → duplicate → web/saved image → panorama →
  Live Photo → HDR → small/thumbnail → unusual aspect ratio → camera photo → uncategorized.
- `categorizeAll(_:)` batch-processes all items and returns both the updated items and
  sorted category tallies for the UI.
- `sourceBreakdown(_:)` groups items by source classification (camera, web, screenshot, etc.)
  and returns sorted tallies.
- `cameraBreakdown(_:)` groups items by camera make/model string and returns sorted tallies,
  useful for identifying which devices contributed the most photos.
- `locationBreakdown(_:)` groups items by reverse-geocoded location name (only items with
  successfully geocoded GPS coordinates are included).
- `detectBursts(_:interval:)` finds sequences of photos captured within a configurable time
  interval (default: 2 seconds) of each other — useful for identifying rapid-fire bursts
  that could be candidates for cleanup.

### Added — Duplicate Review Interface (`DuplicateReviewView.swift`)

- **New file: `DuplicateReviewView.swift`** — a dedicated sheet for reviewing duplicate
  groups one at a time with side-by-side photo comparison.
- Displays all photos in each duplicate group as a horizontal scrollable row of thumbnails
  loaded via `PHImageManager` at 300×300 resolution.
- Each photo shows its filename, pixel dimensions, creation date, and camera model beneath
  the thumbnail.
- The highest-resolution photo in each group is automatically identified as the "best" item
  and marked with a yellow star icon.
- Three action buttons per group:
  - **"Keep Best, Delete Others"** (orange) — queues all items except the best for deletion.
  - **"Keep All"** (default) — skips the group without marking anything for deletion.
  - **"Delete All"** (red) — queues every item in the group for deletion.
- Navigation header shows current group number and total groups with Previous/Next buttons.
- Completion view appears when all groups have been reviewed (or when Done is clicked with
  pending deletions), showing total groups reviewed, items queued for deletion, and a
  "Delete Now" button that triggers the same `processPendingDeletions` batch workflow used
  by the main review interface.
- Done button intelligently routes to the completion view when there are pending deletions
  (rather than silently closing the sheet), matching the fix applied to `ReviewView` in v1.1.2.

### Added — Tabbed Results Dashboard (`ContentView.swift` rewrite)

- Completely redesigned the post-scan results UI with a four-tab segmented picker:
  - **Overview** — summary badges (Total Photos, Flagged, Duplicates, Web Images), the
    existing flagged-items breakdown table, and action buttons.
  - **Categories** — a vertical list of all content categories with icons, color-coded
    percentage bars showing each category's share of the total library, and item counts.
  - **Duplicates** — lists all duplicate groups with item counts and best-resolution info.
    Shows a "Review Duplicates" button when groups exist, or explains Quick Scan mode was
    used when fingerprinting was skipped.
  - **Sources** — source classification breakdown with percentages, a top-15 list of camera
    models found in EXIF data, and a top-15 list of GPS locations with photo counts.
- New scan control bar with "Quick Scan" checkbox toggle (`skipFingerprinting`) that lets
  users skip the fingerprinting and duplicate detection phases for a much faster scan.
- Three-state main view: idle (welcome screen), scanning (phase name + progress bar + counts),
  and results (tabbed dashboard).
- Helper functions `iconForCategory`, `colorForCategory`, `iconForSource`, `colorForSource`
  provide consistent visual treatment for every category and source type across the UI.
- Action buttons now conditionally show "Review Duplicates" (red, only when duplicate groups
  exist) alongside the existing "Review Items", "Create Review Album", and "Export CSV".

### Added — Extended Data Model (`PhotoItem.swift`)

- `SourceClassification` enum with 9 cases: `cameraPhoto`, `editedPhoto`, `webSavedImage`,
  `screenshot`, `panorama`, `hdrPhoto`, `livePhoto`, `depthEffect`, `unknown`.
- `ContentCategory` enum with 10 cases: `screenshots`, `webImages`, `cameraPhotos`,
  `duplicates`, `panoramas`, `livePhotos`, `hdrPhotos`, `smallImages`, `unusualRatio`,
  `uncategorized`.
- `GPSCoordinate` struct with `latitude`, `longitude`, and optional `locationName`.
- `EXIFData` struct with fields for `make`, `model`, `lensModel`, `dateTimeOriginal`, `gps`,
  `orientation`, and a computed `hasCameraInfo` property.
- Extended `PhotoItem` with new properties: `exif`, `sourceClassification`, `contentCategory`,
  `duplicateGroupID`, `isDuplicate`.
- New computed properties: `cameraDescription` (intelligently formats make/model, avoiding
  duplication like "Apple Apple iPhone 15"), `locationDescription`.
- `SourceTally` and `CategoryTally` structs for breakdown display rows.
- `DuplicateGroup` struct with `bestItem` (highest resolution by pixel count) and
  `removableCount` (items.count − 1) computed properties.

### Changed — Five-Phase Scan Pipeline (`ScanViewModel.swift` rewrite)

- Replaced the single-pass scan with a five-phase pipeline, each with its own progress
  tracking and status messaging:
  - **Phase 1: Basic Classification** — the original screenshot/ratio/size detection logic,
    now also builds an `assetMap` (`[String: PHAsset]`) for subsequent phases.
  - **Phase 2: EXIF Metadata Extraction** — concurrent extraction with
    `DispatchSemaphore(value: 6)` limiting to 6 simultaneous asset requests, coordinated
    by a `DispatchGroup`. Progress updates every 50 items.
  - **Phase 3: Source Classification** — runs `EXIFExtractor.classifySource` for each item,
    then builds source tallies and camera breakdown. Reads the `skipFingerprinting` toggle
    on the main thread to decide whether to proceed to Phase 4 or jump to final categorization.
  - **Phase 4: Fingerprint Generation** — concurrent with `DispatchSemaphore(value: 4)` and
    `NSLock`-protected fingerprint map. Progress updates every 20 items. This phase is
    skipped entirely in Quick Scan mode.
  - **Phase 5: Duplicate Detection** — calls `DuplicateDetector.findDuplicateGroups`, marks
    items as duplicates, assigns `duplicateGroupID` values. Also skipped in Quick Scan mode.
  - **Final: Content Categorization** — runs `CategoryAnalyzer.categorizeAll`, then performs
    lightweight reverse geocoding of GPS clusters (up to 50 unique ~1 km grid cells) before
    building location breakdowns and completing the scan.
- `ScanPhase` enum with human-readable raw values displayed in the scanning progress view.
- New `@Published` state: `allItems`, `categoryTallies`, `sourceTallies`, `duplicateGroups`,
  `cameraBreakdown`, `locationBreakdown`, `skipFingerprinting`.
- Reverse geocoding clusters GPS coordinates by rounding to 0.01° (~1 km) grid cells,
  geocodes only the 50 most-populated clusters to avoid Apple's rate limits, then applies
  location names to all items in each cluster.
- CSV export now includes Source, Camera, Category, and Duplicate columns.

### Changed — Review View Metadata Display (`ReviewView.swift`)

- Added camera information display: when a photo has EXIF camera data, a camera icon with
  the `cameraDescription` string is shown in the metadata bar.
- Added source classification tag: a blue capsule label (e.g., "Camera Photo", "Web / Saved
  Image", "Screenshot") is displayed above the existing reason tags on the right side of
  each review item.
- Restructured the right-side layout to a `VStack(alignment: .trailing)` containing the
  source classification tag above the reason tags.

### Changed — Application Icon

- Replaced the pixel-art broom icon with a professional skeuomorphic icon in the pre-macOS
  Tahoe style.
- New design features: a stack of three polaroid-style photographs with painted landscape
  scenes (mountain, beach, forest), a magnifying glass overlay with a green checkmark badge,
  decorative sparkle/star effects, and a dark teal gradient background.
- Generated programmatically via Python/Pillow at 1024×1024 base resolution and downscaled
  with LANCZOS resampling to all 10 required macOS icon sizes: 16×16, 16×16@2x, 32×32,
  32×32@2x, 128×128, 128×128@2x, 256×256, 256×256@2x, 512×512, 512×512@2x.
- Updated `Contents.json` in `Assets.xcassets/AppIcon.appiconset/` to reference all 10 PNGs.

### Changed — Project Configuration (`project.pbxproj`)

- Added `Vision.framework` to PBXFrameworksBuildPhase and Frameworks group.
- Added four new Swift source files to PBXSourcesBuildPhase: `EXIFExtractor.swift`,
  `DuplicateDetector.swift`, `CategoryAnalyzer.swift`, `DuplicateReviewView.swift`.
- Added all four new files to the PhotosCleaner source group.
- Bumped `MARKETING_VERSION` from `1.1` to `2.0`.
- Bumped `CURRENT_PROJECT_VERSION` from `1` to `2`.

### Fixed — Missing `UniformTypeIdentifiers` Import

- Added `import UniformTypeIdentifiers` to `ContentView.swift` to resolve a compile error
  with `UTType.commaSeparatedText` used in the CSV export `NSSavePanel` configuration.
  This import was previously resolved implicitly by Xcode in some configurations but failed
  in clean builds.

### Technical Notes

- **CoreLocation** and **ImageIO** frameworks are auto-linked via `CLANG_MODULES_AUTOLINK`
  (Xcode default: YES) — they do not need explicit entries in the Frameworks build phase.
- The O(n²) duplicate comparison in `DuplicateDetector` is the primary performance bottleneck
  for large libraries. For a 4,000-photo library, expect Phase 4 (fingerprinting) to take
  15–30 minutes and Phase 5 (comparison) to take 1–5 minutes.
- Quick Scan mode skips Phases 4 and 5 entirely, reducing total scan time to roughly
  2–5 minutes for a 4,000-photo library.

---

## [1.1.2] — 2026-03-07

### Summary

A critical bugfix release that resolves batch deletions silently failing when the user clicks
"Done" during review, and adds a proper interstitial completion screen.

### Fixed — Batch Deletions Not Executing on "Done"

- **Root cause:** Clicking "Done" during item review set `isPresented = false`, which closed
  the review sheet immediately. The completion view (where the "Delete Now" batch button
  lives) only appeared when the review queue was fully exhausted (`reviewQueue.isEmpty`).
  If the user clicked "Done" before reviewing every single item, the sheet closed without
  ever showing the batch deletion button, and all queued deletions were silently discarded.
- **Fix:** Added a `@State private var manualComplete: Bool` flag to `ReviewView`. When
  the user clicks "Done" and there are pending deletions (`vm.pendingDeletions` is non-empty),
  the button now sets `manualComplete = true` instead of dismissing the sheet. The
  `isComplete` computed property was updated to `vm.reviewQueue.isEmpty || manualComplete`,
  which triggers the completion view to appear.
- The completion view now shows a "Skipped (still in queue)" count alongside the existing
  Deleted, Kept, and Moved counts, so the user knows how many items were not reviewed.
- The "Delete Now" button on the completion view calls `vm.processPendingDeletions()` which
  invokes `PHAssetChangeRequest.deleteAssets` in a `PHPhotoLibrary.shared().performChanges`
  block — this triggers the system confirmation dialog in Photos.app and executes the batch
  deletion only after the user confirms.

---

## [1.1.1] — 2026-03-07

### Summary

A critical bugfix release that resolves the "Photos access denied" error when running the
archived `.app` outside of Xcode, caused by missing Hardened Runtime entitlements.

### Fixed — Photos Access Denied in Archived .app

- **Root cause:** When building and archiving the app for distribution, Xcode enables
  Hardened Runtime (`ENABLE_HARDENED_RUNTIME = YES`). Hardened Runtime restricts access to
  sensitive user data (including the Photos library) unless the app explicitly declares the
  required entitlements. The app ran fine inside Xcode (which uses a debug signing profile
  that doesn't enforce Hardened Runtime) but failed when exported as a standalone `.app`
  and placed in `/Applications`.
- **Fix:** Added `com.apple.security.personal-information.photos-library` with value `true`
  to `PhotosCleaner.entitlements`. This entitlement tells macOS that the app legitimately
  needs access to the user's photo library, even under Hardened Runtime.
- The entitlements file also sets `com.apple.security.app-sandbox` to `false` since the app
  requires direct PhotoKit access that is incompatible with App Sandbox restrictions.

### Added — Guidance for Resetting Privacy Permissions

- Documented the `tccutil reset Photos ca.gov.ab.richardhenderson.photoscleaner` terminal
  command for removing stale entries from macOS Privacy & Security > Photos settings when
  the app's signing identity changes between debug and release builds.

---

## [1.1.0] — 2026-03-07

### Summary

Added an item-by-item review interface with Delete/Keep/Move actions, Speed Mode for rapid
triage, and batched deletion workflow.

### Added — Item Review Interface (`ReviewView.swift`)

- New `ReviewView` sheet presented from the main results screen.
- Displays each flagged photo as a large preview image loaded via `PHImageManager` at
  600×600 resolution with `.highQualityFormat` delivery mode.
- Metadata bar shows filename, dimensions, creation date, and detection reasons as colored
  capsule tags.
- Three action buttons per item:
  - **Delete** (red) — queues the photo for batch deletion.
  - **Keep** (green) — moves the photo to a "Reviewed: Keep" album in Photos.
  - **Move** (blue) — prompts for an album name and moves the photo there.
- Navigation: Previous/Next buttons, progress counter ("Item 5 of 200").

### Added — Speed Mode

- Toggle in the review toolbar for rapid triage of large libraries (4,000+ items).
- In Speed Mode, action buttons are larger and the interface is optimized for quick
  decision-making without waiting for album operations to complete.

### Added — Batched Deletion Workflow

- Photos are not deleted immediately when the user clicks "Delete" — they are queued in
  `vm.pendingDeletions` and a running count is displayed.
- When review is complete, a completion view shows statistics (deleted, kept, moved, skipped)
  and a "Delete [N] Photos Now" button.
- The batch deletion calls `PHPhotoLibrary.shared().performChanges` with
  `PHAssetChangeRequest.deleteAssets`, which triggers the macOS system confirmation dialog
  in Photos.app before any photos are actually removed.
- `@Published var batchProcessing: Bool` prevents double-submission while a deletion batch
  is in progress.

### Added — Album Operations

- `keepItem(_:completion:)` — adds a photo to the "Reviewed: Keep" album.
- `moveItem(_:toAlbumNamed:completion:)` — adds a photo to a user-specified album.
- `addToAlbum(named:assetID:completion:)` — creates the album if it doesn't exist, then
  adds the asset. Uses `PHAssetCollectionChangeRequest` for creation and
  `PHAssetCollectionChangeRequest(for:).addAssets` for insertion.

### Changed — ScanViewModel

- Added review queue management: `reviewQueue`, `reviewIndex`, `reviewDeleted`, `reviewKept`,
  `reviewMoved`, `pendingDeletions`, `batchProcessing` published properties.
- Added `startReview()`, `removeCurrentFromQueue()`, `queueForDeletion(_:)`,
  `processPendingDeletions(completion:)` methods.

---

## [1.0.0] — 2026-03-07

### Summary

Initial release of PhotosCleaner as a native macOS SwiftUI application. Scans the user's
Apple Photos library via PhotoKit and identifies potential non-photo items based on metadata
heuristics.

### Added — Core Application

- **`PhotosCleanerApp.swift`** — SwiftUI `@main` entry point with a single `WindowGroup`
  scene. Window style set to `.titleBar` with `.unified` toolbar style. Default window size
  720×600. Disabled the File > New menu item.
- **`PhotoItem.swift`** — `Identifiable` struct representing a photo with `id` (PHAsset
  localIdentifier), `filename`, `date`, `width`, `height`, `reasons` array, and computed
  properties for `reasonSummary` and `dateString`.
- **`TallyRow`** — struct for aggregating detection reasons with counts.

### Added — Photo Scanning (`ScanViewModel.swift`)

- `ScanViewModel` as an `ObservableObject` driving the UI with `@Published` state for
  scan progress, results, and error handling.
- Authorization flow: checks `PHPhotoLibrary.authorizationStatus(for: .readWrite)` on
  appear, requests authorization if needed, and displays an error message if denied.
- Fetches all image assets via `PHAsset.fetchAssets(with: .image, options:)` with
  `includeHiddenAssets = false` and `includeAllBurstAssets = false`.
- Classification heuristics (`classify(_ asset:)` static method):
  - Detects screenshots via `PHAssetMediaSubtype.photoScreenshot`.
  - Flags unusual aspect ratios (width/height < 0.5 or > 2.5).
  - Flags very small images (width or height < 200 pixels).
- Progress tracking with `scannedCount`, `totalCount`, and `progress` (0.0–1.0) updated
  every 50 assets.
- Tally generation: aggregates reasons by key (stripping parenthetical dimension details)
  and sorts by count descending.

### Added — Results Display (`ContentView.swift`)

- Dark header bar with app title and version number.
- "Start Scan" button with appropriate disabled/label states during scanning.
- Scanning progress view with spinner, status message, linear progress bar, and item counter.
- Results view with a summary label, flagged items breakdown table (reason + count), and
  action buttons.
- "Create Review Album" button — calls `vm.createAlbum()` to create a
  "Review: Possible Non-Photos" album in the Photos library containing all flagged items.
- "Export CSV" button — opens an `NSSavePanel` (via `NSViewRepresentable` bridge) to save
  a CSV report of all scanned items with filename, date, reasons, and dimensions.

### Added — CSV Export

- `csvContent()` method generates RFC 4180-compliant CSV with proper quoting and
  double-quote escaping.
- Columns: Filename, Date, Reasons, Width, Height.

### Added — Album Creation

- `createAlbum(completion:)` — creates a new Photos album using
  `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`, then adds
  all flagged assets in a second `performChanges` call.

### Added — Application Metadata

- **`Credits.rtf`** — About window credits: "Developed by Claude Opus 4.6 and Richard
  Henderson".
- **`NSHumanReadableCopyright`** build setting for the About window.
- **`PhotosCleaner.entitlements`** — entitlements file with App Sandbox disabled and
  Photos library access entitlement.

### Added — App Icon (v1)

- Pixel art style icon: a broom sweeping in front of a photograph/polaroid frame.
- Generated programmatically via Python/Pillow at all 10 macOS icon sizes.
- `Contents.json` asset catalog configuration for the complete icon set.

### Added — Project Configuration

- Xcode project (`project.pbxproj`) targeting macOS 13.0+, Swift 5.
- Linked frameworks: `Photos.framework`.
- Build settings: `ENABLE_HARDENED_RUNTIME = YES`, `INFOPLIST_KEY_LSApplicationCategoryType`
  set to `public.app-category.photography`.
- App category: Photography.
- Bundle identifier: `ca.gov.ab.richardhenderson.photoscleaner`.

---

## [0.1.0] — 2026-03-07 (Pre-release / Prototype)

### Summary

Original prototype as a standalone Python script using the `osxphotos` library. This version
was superseded by the native SwiftUI app but remains in the repository root as
`sort_photos.py` for reference.

### Added

- Python script (`sort_photos.py`) using the `osxphotos` library to read the macOS Photos
  database and identify non-photo items.
- Basic heuristics for screenshot detection and metadata analysis.
- Console output of results.

### Limitations

- Read-only access — `osxphotos` cannot create albums or delete photos.
- Requires Python 3.10+ and `osxphotos` pip package.
- No graphical interface.
- Superseded by native PhotoKit implementation in v1.0.0.
