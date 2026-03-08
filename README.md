# PhotosCleaner

A native macOS app that scans your Apple Photos library and helps you find screenshots, web-saved images, duplicates, and other non-photo clutter — so you can reclaim space and keep your library clean.

Built with SwiftUI and PhotoKit. No cloud services, no subscriptions, no data leaves your Mac.

## What It Does

PhotosCleaner runs a five-phase analysis of your entire Photos library:

1. **Basic classification** — flags screenshots, tiny images, and unusual aspect ratios
2. **EXIF metadata extraction** — reads camera make/model, lens, GPS coordinates, and timestamps directly from image files
3. **Source classification** — determines whether each photo came from a camera, was saved from the web, is a screenshot, panorama, Live Photo, HDR, or depth-effect image
4. **Perceptual fingerprinting** — generates visual fingerprints using Apple's Vision framework (`VNFeaturePrintObservation`)
5. **Duplicate detection** — compares fingerprints to find visually similar or duplicate photos

Results are presented in a tabbed dashboard with four views:

- **Overview** — summary stats and flagged items breakdown
- **Categories** — every photo categorized (camera, web, screenshot, duplicate, panorama, etc.) with visual percentage bars
- **Duplicates** — grouped duplicate sets with a dedicated side-by-side review interface
- **Sources** — source classification breakdown, top camera models from EXIF, and GPS location grouping

## Screenshots

*Coming soon*

## Features

- **Item-by-item review** with Delete / Keep / Move actions and batched deletion
- **Duplicate review** with side-by-side comparison — automatically identifies the highest-resolution "best" copy
- **Quick Scan mode** skips fingerprinting for a faster scan (~2–5 min vs. 15–30 min for 4,000 photos)
- **GPS location grouping** with reverse geocoding (clusters nearby coordinates, geocodes up to 50 unique locations)
- **CSV export** of the full library analysis with all metadata columns
- **Review album creation** in Photos for flagged items
- **Speed Mode** for rapid triage of large libraries

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15+ to build from source
- Photos library access (prompted on first launch)

## Building

1. Clone the repo
2. Open `PhotosCleaner.xcodeproj` in Xcode
3. Build and run (⌘R)

No external dependencies — the app uses only Apple frameworks: Photos, Vision, CoreLocation, ImageIO, and SwiftUI.

To archive for standalone use: Product → Archive → Distribute App → Copy App.

## Project Structure

```
PhotosCleaner/
├── PhotosCleanerApp.swift      # App entry point
├── ContentView.swift           # Main UI with tabbed results dashboard
├── ScanViewModel.swift         # Five-phase scan pipeline and state management
├── PhotoItem.swift             # Data model (PhotoItem, EXIFData, DuplicateGroup, enums)
├── EXIFExtractor.swift         # EXIF metadata reading and source classification
├── DuplicateDetector.swift     # Vision framework fingerprinting and duplicate grouping
├── CategoryAnalyzer.swift      # Metadata-based content categorization
├── ReviewView.swift            # Item-by-item review interface
├── DuplicateReviewView.swift   # Side-by-side duplicate review interface
├── PhotosCleaner.entitlements  # Hardened Runtime entitlements for Photos access
├── Credits.rtf                 # About window credits
└── Assets.xcassets/            # App icon (skeuomorphic style, all 10 macOS sizes)
```

## How It Works

PhotosCleaner uses only metadata and perceptual hashing — there is no machine learning or cloud API involved.

- **EXIF analysis** reads image properties via `CGImageSourceCopyPropertiesAtIndex` without decoding pixels, so it's fast and memory-efficient.
- **Source classification** checks `PHAsset.mediaSubtypes` (screenshot, panorama, HDR, Live Photo, depth effect) and falls back to EXIF Make/Model presence to distinguish camera photos from web-saved images.
- **Duplicate detection** uses Apple's `VNGenerateImageFeaturePrintRequest` to produce a perceptual fingerprint for each photo, then does pairwise comparison with `computeDistance(to:)`. Photos within a configurable threshold (default: 0.5) are grouped as duplicates.
- **Batch deletions** queue photos during review and execute them in a single `PHPhotoLibrary.performChanges` call, which triggers the standard macOS confirmation dialog.

## Privacy

Everything runs locally on your Mac. PhotosCleaner does not connect to any server, collect analytics, or transmit any data. GPS reverse geocoding uses Apple's `CLGeocoder`, which is an on-device/Apple-only service.

## Authors

Developed by **Claude Opus 4.6** and **Richard Henderson**.

## License

This project is provided as-is for personal use.
