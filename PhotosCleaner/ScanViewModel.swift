import Foundation
import Photos
import Vision

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
    case classifying            = "Phase 1/5: Basic Classification"
    case extractingEXIF         = "Phase 2/5: Reading EXIF Metadata"
    case classifyingSources     = "Phase 3/5: Classifying Sources"
    case generatingFingerprints = "Phase 4/5: Generating Fingerprints"
    case detectingDuplicates    = "Phase 5/5: Detecting Duplicates"
    case complete               = "Scan Complete"
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

    // ── Results ─────────────────────────────────────────────────────────────
    @Published var allItems        = [PhotoItem]()   // Every photo in the library
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

    // Convenience computed properties
    var isScanning: Bool {
        scanPhase != .idle && scanPhase != .complete
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

    // ── Scan Entry Point ────────────────────────────────────────────────────

    func startScan() {
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

        // Reset state
        scanPhase         = .classifying
        allItems          = []
        flaggedItems      = []
        tallyRows         = []
        categoryTallies   = []
        sourceTallies     = []
        duplicateGroups   = []
        cameraBreakdown   = []
        locationBreakdown = []
        fingerprints      = [:]
        progress          = 0
        scannedCount      = 0
        errorMessage      = nil

        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets   = false
        fetchOptions.includeAllBurstAssets = false

        let result = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let total  = result.count
        totalCount = total
        statusMessage = "Phase 1/5 — Classifying \(total.formatted()) photos…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.phase1Classify(result: result, total: total)
        }
    }

    // ── Phase 1: Basic Classification ───────────────────────────────────────

    private func phase1Classify(result: PHFetchResult<PHAsset>, total: Int) {
        var items = [PhotoItem]()
        var tally = [String: Int]()
        var assetMap = [String: PHAsset]()

        result.enumerateObjects { asset, index, _ in
            let reasons = Self.classify(asset)
            let filename = PHAssetResource.assetResources(for: asset)
                .first?.originalFilename ?? asset.localIdentifier

            let item = PhotoItem(
                id:       asset.localIdentifier,
                filename: filename,
                date:     asset.creationDate,
                width:    asset.pixelWidth,
                height:   asset.pixelHeight,
                reasons:  reasons
            )
            items.append(item)
            assetMap[asset.localIdentifier] = asset

            for r in reasons {
                let key = r.components(separatedBy: " (").first ?? r
                tally[key, default: 0] += 1
            }

            if index % 50 == 0 || index == total - 1 {
                let p = Double(index + 1) / Double(max(total, 1))
                let c = index + 1
                DispatchQueue.main.async { [weak self] in
                    self?.progress     = p
                    self?.scannedCount = c
                }
            }
        }

        let sortedTally = tally
            .sorted { $0.value > $1.value }
            .map { TallyRow(reason: $0.key, count: $0.value) }

        DispatchQueue.main.async { [weak self] in
            self?.allItems     = items
            self?.flaggedItems = items.filter { !$0.reasons.isEmpty }
            self?.tallyRows    = sortedTally
        }

        phase2ExtractEXIF(items: items, assetMap: assetMap, total: total)
    }

    // ── Phase 2: EXIF Metadata Extraction ───────────────────────────────────

    private func phase2ExtractEXIF(items: [PhotoItem], assetMap: [String: PHAsset], total: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.scanPhase     = .extractingEXIF
            self?.statusMessage = "Phase 2/5 — Reading EXIF metadata…"
            self?.progress      = 0
            self?.scannedCount  = 0
        }

        var updated   = items
        let semaphore = DispatchSemaphore(value: 6)
        let group     = DispatchGroup()
        let lock      = NSLock()
        var completed = 0

        for i in 0..<updated.count {
            guard let asset = assetMap[updated[i].id] else { continue }

            semaphore.wait()
            group.enter()

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
        }

        group.wait()
        phase3ClassifySources(items: updated, assetMap: assetMap, total: total)
    }

    // ── Phase 3: Source Classification ───────────────────────────────────────

    private func phase3ClassifySources(items: [PhotoItem], assetMap: [String: PHAsset], total: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.scanPhase     = .classifyingSources
            self?.statusMessage = "Phase 3/5 — Classifying photo sources…"
            self?.progress      = 0
        }

        var updated = items

        for i in 0..<updated.count {
            if let asset = assetMap[updated[i].id] {
                updated[i].sourceClassification = EXIFExtractor.classifySource(
                    asset: asset, exif: updated[i].exif
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
            phase4GenerateFingerprints(items: updated, assetMap: assetMap, total: total)
        }
    }

    // ── Phase 4: Fingerprint Generation ─────────────────────────────────────

    private func phase4GenerateFingerprints(items: [PhotoItem], assetMap: [String: PHAsset], total: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.scanPhase     = .generatingFingerprints
            self?.statusMessage = "Phase 4/5 — Generating perceptual fingerprints (this may take a while)…"
            self?.progress      = 0
            self?.scannedCount  = 0
        }

        let semaphore = DispatchSemaphore(value: 4)
        let group     = DispatchGroup()
        let lock      = NSLock()
        var fpMap     = [String: VNFeaturePrintObservation]()
        var completed = 0

        for item in items {
            guard let asset = assetMap[item.id] else { continue }

            semaphore.wait()
            group.enter()

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
        }

        group.wait()

        DispatchQueue.main.async { [weak self] in
            self?.fingerprints = fpMap
        }

        phase5DetectDuplicates(items: items, fingerprints: fpMap)
    }

    // ── Phase 5: Duplicate Detection ────────────────────────────────────────

    private func phase5DetectDuplicates(items: [PhotoItem], fingerprints fpMap: [String: VNFeaturePrintObservation]) {
        DispatchQueue.main.async { [weak self] in
            self?.scanPhase     = .detectingDuplicates
            self?.statusMessage = "Phase 5/5 — Comparing fingerprints for duplicates…"
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

        // Reverse-geocode unique GPS clusters (up to 50) for the Locations tab.
        // Cluster by rounding to ~0.01° (~1 km), then geocode one representative per cluster.
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

                if flagCount == 0 && dupCount == 0 {
                    self.statusMessage = "Scan complete — your library looks clean!"
                } else {
                    var parts = [String]()
                    if flagCount > 0  { parts.append("\(flagCount.formatted()) flagged items") }
                    if dupCount > 0   { parts.append("\(dupCount.formatted()) duplicate groups") }
                    self.statusMessage = "Scan complete. Found \(parts.joined(separator: " and ")) out of \(categorized.count.formatted()) photos."
                }
            }
        }
    }

    /// Reverse-geocode GPS coordinates for location grouping.
    /// Clusters coordinates by ~1 km grid cells, geocodes up to 50 unique clusters,
    /// then applies the location name to all items in each cluster.
    private func reverseGeocodeLocations(_ items: [PhotoItem], completion: @escaping ([PhotoItem]) -> Void) {
        // Build clusters: round lat/lon to 0.01° (~1 km) grid
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

        // Limit to 50 most-populated clusters to avoid rate limiting
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
        let identifiers = flaggedItems.map { $0.id }
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
        let ids = pendingDeletions.map { $0.id }
        guard !ids.isEmpty else {
            completion(.success(0))
            return
        }
        batchProcessing = true
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.batchProcessing = false
                if let error { completion(.failure(error)) }
                else {
                    let count = ids.count
                    self?.pendingDeletions = []
                    completion(.success(count))
                }
            }
        }
    }

    func keepItem(_ item: PhotoItem, completion: @escaping (Error?) -> Void) {
        addToAlbum(named: "Reviewed: Keep", assetID: item.id, completion: completion)
    }

    func moveItem(_ item: PhotoItem, toAlbumNamed name: String, completion: @escaping (Error?) -> Void) {
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
        var lines = ["Filename,Date,Reasons,Width,Height,Source,Camera,Category,Duplicate"]
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
                item.isDuplicate ? "Yes" : "No"
            ].map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
