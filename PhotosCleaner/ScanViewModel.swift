//
// This file is part of PhotosCleaner.
// Copyright (C) 2026 Richard Henderson
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import Photos
import Vision
import AppKit

// MARK: - Errors

enum AppError: LocalizedError {
    case albumCreationFailed
    case photosAccessDenied

    var errorDescription: String? {
        switch self {
        case .albumCreationFailed:
            return "Could not create the review album in Photos. Please try again."
        case .photosAccessDenied:
            return "Photos access is required. Please enable it in System Settings > Privacy & Security > Photos."
        }
    }
}

// MARK: - Scan Phase

enum ScanPhase: String {
    case idle                   = "Idle"
    case enumeratingFolder      = "Phase 0/6: Scanning Folder"
    case classifying            = "Phase 1/6: Basic Classification"
    case extractingEXIF         = "Phase 2/6: Reading EXIF Metadata"
    case classifyingSources     = "Phase 3/6: Classifying Sources"
    case generatingFingerprints = "Phase 4/6: Generating Fingerprints"
    case detectingDuplicates    = "Phase 5/6: Detecting Duplicates"
    case complete               = "Scan Complete"
    case cancelled              = "Scan Stopped"
}

// MARK: - ViewModel

class ScanViewModel: ObservableObject {

    static let albumName = "Review: Possible Non-Photos"

    // ── Scan state ──────────────────────────────────────────────────────────
    @Published var scanPhase: ScanPhase = .idle
    @Published var authStatus: PHAuthorizationStatus = .notDetermined
    @Published var statusMessage  = "Ready to scan your Photos library."
    @Published var progress: Double = 0
    @Published var scannedCount   = 0
    @Published var totalCount     = 0
    @Published var errorMessage: String? = nil

    /// Skip fingerprinting & duplicate detection for a faster scan.
    @Published var skipFingerprinting: Bool = false

    // ── Source selection (v3) ─────────────────────────────────────────────
    @Published var scanPhotoKit: Bool = true
    @Published var scanFileSystem: Bool = false
    @Published var selectedFolderURL: URL? = nil
    @Published var folderPhotoCount: Int = 0

    // ── Results ─────────────────────────────────────────────────────────────
    @Published var allItems        = [PhotoItem]()   // Every photo scanned
    @Published var flaggedItems    = [PhotoItem]()   // Items with non-empty reasons
    @Published var tallyRows       = [TallyRow]()

    // v2 results
    @Published var categoryTallies      = [CategoryTally]()
    @Published var sourceTallies        = [SourceTally]()
    @Published var duplicateGroups      = [DuplicateGroup]()
    @Published var cameraBreakdown      = [(camera: String, count: Int)]()
    @Published var locationBreakdown    = [(location: String, count: Int)]()

    // Fingerprint storage (in-memory only)
    private var fingerprints = [String: VNFeaturePrintObservation]()

    // Cancellation flag — thread-safe via NSLock
    private var _cancelled = false
    private let cancelLock = NSLock()

    private var isCancelled: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelled }
        set { cancelLock.lock(); _cancelled = newValue; cancelLock.unlock() }
    }

    // Asset map for PhotoKit photos (needed for image loading and deletion)
    private var assetMap = [String: PHAsset]()

    // File URLs discovered during folder enumeration (v3)
    private var folderImageURLs = [URL]()

    // Convenience computed properties
    var isScanning: Bool {
        scanPhase != .idle && scanPhase != .complete && scanPhase != .cancelled
    }

    var scanComplete: Bool {
        scanPhase == .complete
    }

    // ── Authorization ───────────────────────────────────────────────────────

    func checkAuthorization() {
        authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization(completion: @escaping (PHAuthorizationStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                self?.authStatus = status
                completion(status)
            }
        }
    }

    // ── Stop Scan ─────────────────────────────────────────────────────────

    func stopScan() {
        isCancelled = true
    }

    /// Called from background threads to check cancellation and transition to cancelled state.
    private func handleCancellation(partialItems: [PhotoItem] = [], partialTallies: [TallyRow] = []) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !partialItems.isEmpty {
                self.allItems     = partialItems
                self.flaggedItems = partialItems.filter { !$0.reasons.isEmpty }
            }
            if !partialTallies.isEmpty {
                self.tallyRows = partialTallies
            }
            let phase = self.scanPhase.rawValue
            self.scanPhase     = .cancelled
            self.statusMessage = "Scan stopped during \(phase). Partial results shown for \(self.allItems.count.formatted()) photos."
            self.progress      = 0
        }
    }

    // ── Scan Entry Point ────────────────────────────────────────────────────

    func startScan() {
        // Need at least one source selected
        guard scanPhotoKit || scanFileSystem else {
            errorMessage = "Please select at least one source to scan (Photos Library or Folder)."
            return
        }

        // If scanning PhotoKit, ensure authorization
        if scanPhotoKit {
            let authorized = authStatus == .authorized || authStatus == .limited
            guard authorized else {
                requestAuthorization { [weak self] status in
                    if status == .authorized || status == .limited {
                        self?.startScan()
                    } else {
                        self?.errorMessage = AppError.photosAccessDenied.errorDescription
                    }
                }
                return
            }
        }

        // Reset state
        isCancelled        = false
        allItems           = []
        flaggedItems       = []
        tallyRows          = []
        categoryTallies    = []
        sourceTallies      = []
        duplicateGroups    = []
        cameraBreakdown    = []
        locationBreakdown  = []
        fingerprints       = [:]
        assetMap           = [:]
        folderImageURLs    = []
        folderPhotoCount   = 0
        progress           = 0
        scannedCount       = 0
        totalCount         = 0
        errorMessage       = nil

        // Clear thumbnail cache for fresh scan
        ThumbnailCache.shared.clear()

        // Start with folder enumeration if filesystem scanning is enabled
        if scanFileSystem, let folderURL = selectedFolderURL {
            scanPhase     = .enumeratingFolder
            statusMessage = "Phase 0/6 — Scanning folder…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.phase0EnumerateFolder(folderURL: folderURL)
            }
        } else {
            // Skip straight to Phase 1
            scanPhase     = .classifying
            statusMessage = "Phase 1/6 — Classifying photos…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.phase1Classify()
            }
        }
    }

    // ── Phase 0: Folder Enumeration (v3) ─────────────────────────────────

    private func phase0EnumerateFolder(folderURL: URL) {
        let urls = FileSystemScanner.enumerateImages(in: folderURL)

        if isCancelled {
            handleCancellation()
            return
        }

        folderImageURLs = urls

        DispatchQueue.main.async { [weak self] in
            self?.folderPhotoCount = urls.count
            self?.statusMessage = "Found \(urls.count.formatted()) images in folder. Starting classification…"
        }

        // Continue to Phase 1
        DispatchQueue.main.async { [weak self] in
            self?.scanPhase     = .classifying
            self?.statusMessage = "Phase 1/6 — Classifying photos…"
        }

        phase1Classify()
    }

    // ── Phase 1: Basic Classification ───────────────────────────────────────

    private func phase1Classify() {
        var items = [PhotoItem]()
        var tally = [String: Int]()

        // 1a. PhotoKit photos
        if scanPhotoKit {
            let fetchOptions = PHFetchOptions()
            fetchOptions.includeHiddenAssets   = false
            fetchOptions.includeAllBurstAssets = false

            let result = PHAsset.fetchAssets(with: .image, options: fetchOptions)

            result.enumerateObjects { [weak self] asset, index, stop in
                if self?.isCancelled == true {
                    stop.pointee = true
                    return
                }
                let reasons = Self.classify(asset)
                let filename = PHAssetResource.assetResources(for: asset)
                    .first?.originalFilename ?? asset.localIdentifier

                let item = PhotoItem(
                    id:       asset.localIdentifier,
                    filename: filename,
                    date:     asset.creationDate,
                    width:    asset.pixelWidth,
                    height:   asset.pixelHeight,
                    reasons:  reasons,
                    photoSource: .photoKit
                )
                items.append(item)
                self?.assetMap[asset.localIdentifier] = asset

                for r in reasons {
                    let key = r.components(separatedBy: " (").first ?? r
                    tally[key, default: 0] += 1
                }
            }
        }

        if isCancelled {
            let sortedTally = tally.sorted { $0.value > $1.value }.map { TallyRow(reason: $0.key, count: $0.value) }
            handleCancellation(partialItems: items, partialTallies: sortedTally)
            return
        }

        // 1b. Filesystem photos
        for (index, url) in folderImageURLs.enumerated() {
            if isCancelled { break }

            let meta = FileSystemScanner.loadImageMetadata(from: url)
            let filename = url.lastPathComponent
            let reasons = FileSystemScanner.classifyFileSystemImage(
                filename: filename, width: meta.width, height: meta.height
            )

            let item = PhotoItem(
                id:       url.absoluteString,
                filename: filename,
                date:     meta.date,
                width:    meta.width,
                height:   meta.height,
                reasons:  reasons,
                photoSource: .fileSystem,
                fileURL:  url
            )
            items.append(item)

            for r in reasons {
                let key = r.components(separatedBy: " (").first ?? r
                tally[key, default: 0] += 1
            }

            if index % 50 == 0 {
                let c = items.count
                DispatchQueue.main.async { [weak self] in
                    self?.scannedCount = c
                }
            }
        }

        let total = items.count
        let sortedTally = tally
            .sorted { $0.value > $1.value }
            .map { TallyRow(reason: $0.key, count: $0.value) }

        if isCancelled {
            handleCancellation(partialItems: items, partialTallies: sortedTally)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.totalCount   = total
            self?.allItems     = items
            self?.flaggedItems = items.filter { !$0.reasons.isEmpty }
            self?.tallyRows    = sortedTally
            self?.progress     = 1.0
            self?.scannedCount = total
            self?.statusMessage = "Phase 1/6 — Classified \(total.formatted()) photos."
        }

        phase2ExtractEXIF(items: items, total: total)
    }

    // ── Phase 2: EXIF Metadata Extraction ───────────────────────────────────

    private func phase2ExtractEXIF(items: [PhotoItem], total: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.scanPhase     = .extractingEXIF
            self?.statusMessage = "Phase 2/6 — Reading EXIF metadata…"
            self?.progress      = 0
            self?.scannedCount  = 0
        }

        var updated   = items
        let semaphore = DispatchSemaphore(value: HardwareAdaptor.exifConcurrency)
        let group     = DispatchGroup()
        let lock      = NSLock()
        var completed = 0

        for i in 0..<updated.count {
            if isCancelled { break }

            semaphore.wait()
            group.enter()

            let item = updated[i]

            if item.photoSource == .photoKit, let asset = assetMap[item.id] {
                // PhotoKit path
                EXIFExtractor.extract(from: asset) { exif in
                    lock.lock()
                    updated[i].exif = exif
                    completed += 1
                    let c = completed
                    lock.unlock()

                    semaphore.signal()
                    group.leave()

                    if c % 50 == 0 || c == total {
                        let p = Double(c) / Double(max(total, 1))
                        DispatchQueue.main.async { [weak self] in
                            self?.progress     = p
                            self?.scannedCount = c
                        }
                    }
                }
            } else if item.photoSource == .fileSystem, let url = item.fileURL {
                // Filesystem path
                EXIFExtractor.extractFromFile(at: url) { exif in
                    lock.lock()
                    updated[i].exif = exif
                    completed += 1
                    let c = completed
                    lock.unlock()

                    semaphore.signal()
                    group.leave()

                    if c % 50 == 0 || c == total {
                        let p = Double(c) / Double(max(total, 1))
                        DispatchQueue.main.async { [weak self] in
                            self?.progress     = p
                            self?.scannedCount = c
                        }
                    }
                }
            } else {
                lock.lock()
                completed += 1
                lock.unlock()
                semaphore.signal()
                group.leave()
            }
        }

        group.wait()

        if isCancelled {
            handleCancellation(partialItems: updated)
            return
        }

        phase3ClassifySources(items: updated, total: total)
    }

    // ── Phase 3: Source Classification ───────────────────────────────────────

    private func phase3ClassifySources(items: [PhotoItem], total: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.scanPhase     = .classifyingSources
            self?.statusMessage = "Phase 3/6 — Classifying photo sources…"
            self?.progress      = 0
        }

        var updated = items

        for i in 0..<updated.count {
            if isCancelled { break }

            if updated[i].photoSource == .photoKit, let asset = assetMap[updated[i].id] {
                updated[i].sourceClassification = EXIFExtractor.classifySource(
                    asset: asset, exif: updated[i].exif
                )
            } else if updated[i].photoSource == .fileSystem {
                updated[i].sourceClassification = EXIFExtractor.classifySourceFromFile(
                    filename: updated[i].filename, exif: updated[i].exif
                )
            }

            if i % 100 == 0 || i == total - 1 {
                let p = Double(i + 1) / Double(max(total, 1))
                DispatchQueue.main.async { [weak self] in
                    self?.progress     = p
                    self?.scannedCount = i + 1
                }
            }
        }

        if isCancelled {
            handleCancellation(partialItems: updated)
            return
        }

        let sTallies = CategoryAnalyzer.sourceBreakdown(updated)
        let camBreak = CategoryAnalyzer.cameraBreakdown(updated)

        DispatchQueue.main.async { [weak self] in
            self?.allItems        = updated
            self?.flaggedItems    = updated.filter { !$0.reasons.isEmpty }
            self?.sourceTallies   = sTallies
            self?.cameraBreakdown = camBreak
        }

        // Check if user opted to skip fingerprinting
        let skip: Bool = {
            var val = false
            DispatchQueue.main.sync { [weak self] in val = self?.skipFingerprinting ?? false }
            return val
        }()

        if skip {
            phaseFinalCategorize(items: updated)
        } else {
            phase4GenerateFingerprints(items: updated, total: total)
        }
    }

    // ── Phase 4: Fingerprint Generation ─────────────────────────────────────

    private func phase4GenerateFingerprints(items: [PhotoItem], total: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.scanPhase     = .generatingFingerprints
            self?.statusMessage = "Phase 4/6 — Generating perceptual fingerprints (this may take a while)…"
            self?.progress      = 0
            self?.scannedCount  = 0
        }

        let semaphore = DispatchSemaphore(value: HardwareAdaptor.fingerprintConcurrency)
        let group     = DispatchGroup()
        let lock      = NSLock()
        var fpMap     = [String: VNFeaturePrintObservation]()
        var completed = 0

        for item in items {
            if isCancelled { break }

            semaphore.wait()
            group.enter()

            if item.photoSource == .photoKit, let asset = assetMap[item.id] {
                // PhotoKit path
                DuplicateDetector.generateFingerprint(for: asset) { [weak self] observation in
                    if let obs = observation {
                        lock.lock()
                        fpMap[item.id] = obs
                        lock.unlock()
                    }

                    lock.lock()
                    completed += 1
                    let c = completed
                    lock.unlock()

                    semaphore.signal()
                    group.leave()

                    if c % 20 == 0 || c == total {
                        let p = Double(c) / Double(max(total, 1))
                        DispatchQueue.main.async {
                            self?.progress     = p
                            self?.scannedCount = c
                        }
                    }
                }
            } else if item.photoSource == .fileSystem, let url = item.fileURL {
                // Filesystem path
                DuplicateDetector.generateFingerprintFromFile(at: url) { [weak self] observation in
                    if let obs = observation {
                        lock.lock()
                        fpMap[item.id] = obs
                        lock.unlock()
                    }

                    lock.lock()
                    completed += 1
                    let c = completed
                    lock.unlock()

                    semaphore.signal()
                    group.leave()

                    if c % 20 == 0 || c == total {
                        let p = Double(c) / Double(max(total, 1))
                        DispatchQueue.main.async {
                            self?.progress     = p
                            self?.scannedCount = c
                        }
                    }
                }
            } else {
                lock.lock()
                completed += 1
                lock.unlock()
                semaphore.signal()
                group.leave()
            }
        }

        group.wait()

        if isCancelled {
            handleCancellation(partialItems: items)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.fingerprints = fpMap
        }

        phase5DetectDuplicates(items: items, fingerprints: fpMap)
    }

    // ── Phase 5: Duplicate Detection ────────────────────────────────────────

    private func phase5DetectDuplicates(items: [PhotoItem], fingerprints fpMap: [String: VNFeaturePrintObservation]) {
        DispatchQueue.main.async { [weak self] in
            self?.scanPhase     = .detectingDuplicates
            self?.statusMessage = "Phase 5/6 — Comparing fingerprints for duplicates…"
            self?.progress      = 0
        }

        let groups = DuplicateDetector.findDuplicateGroups(items: items, fingerprints: fpMap)

        // Mark items as duplicates
        var updated = items
        let dupIDs = Set(groups.flatMap { $0.items.map { $0.id } })
        for i in updated.indices {
            if dupIDs.contains(updated[i].id) {
                updated[i].isDuplicate = true
                if let g = groups.first(where: { $0.items.contains(where: { $0.id == updated[i].id }) }) {
                    updated[i].duplicateGroupID = g.id
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.allItems        = updated
            self?.flaggedItems    = updated.filter { !$0.reasons.isEmpty }
            self?.duplicateGroups = groups
        }

        phaseFinalCategorize(items: updated)
    }

    // ── Final: Content Categorization ───────────────────────────────────────

    private func phaseFinalCategorize(items: [PhotoItem]) {
        let (categorized, catTallies) = CategoryAnalyzer.categorizeAll(items)

        reverseGeocodeLocations(categorized) { [weak self] geoItems in
            let locBreak = CategoryAnalyzer.locationBreakdown(geoItems)

            DispatchQueue.main.async {
                guard let self else { return }
                self.allItems          = geoItems
                self.flaggedItems      = geoItems.filter { !$0.reasons.isEmpty }
                self.categoryTallies   = catTallies
                self.locationBreakdown = locBreak
                self.progress          = 1.0
                self.scannedCount      = geoItems.count
                self.scanPhase         = .complete

                let dupCount  = self.duplicateGroups.count
                let flagCount = self.flaggedItems.count

                // Build status message with source breakdown
                var sourceParts = [String]()
                let photoKitCount = geoItems.filter { $0.photoSource == .photoKit }.count
                let folderCount   = geoItems.filter { $0.photoSource == .fileSystem }.count
                if photoKitCount > 0 { sourceParts.append("\(photoKitCount.formatted()) from Photos") }
                if folderCount > 0   { sourceParts.append("\(folderCount.formatted()) from folder") }

                if flagCount == 0 && dupCount == 0 {
                    self.statusMessage = "Scan complete (\(sourceParts.joined(separator: ", "))) — your library looks clean!"
                } else {
                    var parts = [String]()
                    if flagCount > 0  { parts.append("\(flagCount.formatted()) flagged items") }
                    if dupCount > 0   { parts.append("\(dupCount.formatted()) duplicate groups") }
                    self.statusMessage = "Scan complete. Found \(parts.joined(separator: " and ")) out of \(categorized.count.formatted()) photos (\(sourceParts.joined(separator: ", ")))."
                }
            }
        }
    }

    /// Reverse-geocode GPS coordinates for location grouping.
    private func reverseGeocodeLocations(_ items: [PhotoItem], completion: @escaping ([PhotoItem]) -> Void) {
        struct GridKey: Hashable {
            let latBucket: Int
            let lonBucket: Int
        }

        var clusters = [GridKey: (coord: GPSCoordinate, indices: [Int])]()

        for (i, item) in items.enumerated() {
            guard let gps = item.exif.gps else { continue }
            let key = GridKey(
                latBucket: Int((gps.latitude * 100).rounded()),
                lonBucket: Int((gps.longitude * 100).rounded())
            )
            if clusters[key] == nil {
                clusters[key] = (coord: gps, indices: [i])
            } else {
                clusters[key]!.indices.append(i)
            }
        }

        let topClusters = clusters.values
            .sorted { $0.indices.count > $1.indices.count }
            .prefix(50)

        guard !topClusters.isEmpty else {
            completion(items)
            return
        }

        var updated = items
        let lock = NSLock()
        let group = DispatchGroup()

        for cluster in topClusters {
            group.enter()
            EXIFExtractor.reverseGeocode(cluster.coord) { name in
                if let name {
                    lock.lock()
                    for idx in cluster.indices {
                        updated[idx].exif.gps?.locationName = name
                    }
                    lock.unlock()
                }
                group.leave()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            group.wait()
            completion(updated)
        }
    }

    // ── Classification (static — safe to call from any thread) ──────────────

    static func classify(_ asset: PHAsset) -> [String] {
        var reasons = [String]()

        if asset.mediaSubtypes.contains(.photoScreenshot) {
            return ["screenshot"]
        }

        let w = asset.pixelWidth
        let h = asset.pixelHeight

        if h > 0 {
            let ratio = Double(w) / Double(h)
            if ratio < 0.5 || ratio > 2.5 {
                reasons.append("unusual aspect ratio (\(w)×\(h))")
            }
        }

        if w > 0 && h > 0 && (w < 200 || h < 200) {
            reasons.append("very small (\(w)×\(h)px)")
        }

        return reasons
    }

    // ── Album creation ──────────────────────────────────────────────────────

    func createAlbum(completion: @escaping (Result<Int, Error>) -> Void) {
        let identifiers = flaggedItems.compactMap { $0.photoSource == .photoKit ? $0.id : nil }
        guard !identifiers.isEmpty else {
            completion(.success(0))
            return
        }
        var collectionID: String?

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: Self.albumName)
            collectionID = req.placeholderForCreatedAssetCollection.localIdentifier
        }) { success, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let cid = collectionID,
                  let collection = PHAssetCollection
                    .fetchAssetCollections(withLocalIdentifiers: [cid], options: nil)
                    .firstObject
            else {
                DispatchQueue.main.async { completion(.failure(AppError.albumCreationFailed)) }
                return
            }

            let assetsToAdd = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            PHPhotoLibrary.shared().performChanges({
                PHAssetCollectionChangeRequest(for: collection)?.addAssets(assetsToAdd)
            }) { _, error in
                DispatchQueue.main.async {
                    if let error { completion(.failure(error)) }
                    else         { completion(.success(identifiers.count)) }
                }
            }
        }
    }

    // ── Review queue ────────────────────────────────────────────────────────

    @Published var reviewQueue:       [PhotoItem] = []
    @Published var reviewIndex:       Int = 0
    @Published var reviewDeleted:     Int = 0
    @Published var reviewKept:        Int = 0
    @Published var reviewMoved:       Int = 0
    @Published var pendingDeletions:  [PhotoItem] = []
    @Published var batchProcessing:   Bool = false

    func startReview() {
        reviewQueue       = flaggedItems
        reviewIndex       = 0
        reviewDeleted     = 0
        reviewKept        = 0
        reviewMoved       = 0
        pendingDeletions  = []
        batchProcessing   = false
    }

    func removeCurrentFromQueue() {
        guard reviewIndex < reviewQueue.count else { return }
        reviewQueue.remove(at: reviewIndex)
        if reviewIndex >= reviewQueue.count && reviewIndex > 0 {
            reviewIndex -= 1
        }
    }

    // ── Review actions ──────────────────────────────────────────────────────

    func queueForDeletion(_ item: PhotoItem) {
        pendingDeletions.append(item)
        reviewDeleted += 1
        removeCurrentFromQueue()
    }

    func processPendingDeletions(completion: @escaping (Result<Int, Error>) -> Void) {
        guard !pendingDeletions.isEmpty else {
            completion(.success(0))
            return
        }
        batchProcessing = true

        // Split by source
        let photoKitItems = pendingDeletions.filter { $0.photoSource == .photoKit }
        let fileSystemItems = pendingDeletions.filter { $0.photoSource == .fileSystem }

        let group = DispatchGroup()
        let lock = NSLock()
        var deletedCount = 0
        var lastError: Error? = nil

        // Delete PhotoKit items
        if !photoKitItems.isEmpty {
            group.enter()
            let ids = photoKitItems.map { $0.id }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }) { _, error in
                lock.lock()
                if let error {
                    lastError = error
                } else {
                    deletedCount += ids.count
                }
                lock.unlock()
                group.leave()
            }
        }

        // Delete filesystem items (move to Trash)
        if !fileSystemItems.isEmpty {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for item in fileSystemItems {
                    guard let url = item.fileURL else { continue }
                    NSWorkspace.shared.recycle([url]) { trashedURLs, error in
                        lock.lock()
                        if error != nil {
                            lastError = error
                        } else {
                            deletedCount += 1
                        }
                        lock.unlock()
                    }
                }
                group.leave()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            group.wait()
            DispatchQueue.main.async {
                self?.batchProcessing = false
                if let error = lastError, deletedCount == 0 {
                    completion(.failure(error))
                } else {
                    self?.pendingDeletions = []
                    completion(.success(deletedCount))
                }
            }
        }
    }

    func keepItem(_ item: PhotoItem, completion: @escaping (Error?) -> Void) {
        guard item.photoSource == .photoKit else {
            completion(nil)  // No album for filesystem items
            return
        }
        addToAlbum(named: "Reviewed: Keep", assetID: item.id, completion: completion)
    }

    func moveItem(_ item: PhotoItem, toAlbumNamed name: String, completion: @escaping (Error?) -> Void) {
        guard item.photoSource == .photoKit else {
            completion(nil)  // No album for filesystem items
            return
        }
        addToAlbum(named: name, assetID: item.id, completion: completion)
    }

    private func addToAlbum(named albumName: String, assetID: String, completion: @escaping (Error?) -> Void) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: fetchOptions)

        if let collection = existing.firstObject {
            PHPhotoLibrary.shared().performChanges({
                PHAssetCollectionChangeRequest(for: collection)?.addAssets(assets)
            }) { _, error in
                DispatchQueue.main.async { completion(error) }
            }
        } else {
            var newID: String?
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: albumName)
                newID = req.placeholderForCreatedAssetCollection.localIdentifier
            }) { _, error in
                if let error {
                    DispatchQueue.main.async { completion(error) }
                    return
                }
                guard let cid = newID,
                      let collection = PHAssetCollection
                        .fetchAssetCollections(withLocalIdentifiers: [cid], options: nil)
                        .firstObject
                else {
                    DispatchQueue.main.async { completion(AppError.albumCreationFailed) }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCollectionChangeRequest(for: collection)?.addAssets(assets)
                }) { _, error in
                    DispatchQueue.main.async { completion(error) }
                }
            }
        }
    }

    // ── CSV export ──────────────────────────────────────────────────────────

    func csvContent() -> String {
        var lines = ["Filename,Date,Reasons,Width,Height,Source,Camera,Category,Duplicate,PhotoSource"]
        for item in allItems {
            let fields = [
                item.filename,
                item.dateString,
                item.reasonSummary,
                "\(item.width)",
                "\(item.height)",
                item.sourceClassification.rawValue,
                item.cameraDescription,
                item.contentCategory.rawValue,
                item.isDuplicate ? "Yes" : "No",
                item.photoSource.rawValue
            ].map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
