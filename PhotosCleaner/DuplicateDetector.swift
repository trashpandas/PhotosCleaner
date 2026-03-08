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

// MARK: - Duplicate Detector

/// Generates perceptual fingerprints using Vision's VNFeaturePrintObservation
/// and groups visually similar photos as duplicates.
enum DuplicateDetector {

    /// Distance threshold — pairs closer than this are considered duplicates.
    /// 0.0 = identical, lower = more similar. Typical range for near-dupes: 0.0–0.6
    static let threshold: Float = 0.5

    // MARK: - Fingerprint Generation

    /// Generate a VNFeaturePrintObservation for a single PHAsset.
    /// Returns nil if the image can't be loaded or the request fails.
    static func generateFingerprint(
        for asset: PHAsset,
        imageManager: PHImageManager = .default(),
        completion: @escaping (VNFeaturePrintObservation?) -> Void
    ) {
        let opts = PHImageRequestOptions()
        opts.deliveryMode          = .highQualityFormat
        opts.isNetworkAccessAllowed = false
        opts.isSynchronous          = false
        opts.resizeMode             = .fast

        imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: 512, height: 512),
            contentMode: .aspectFill,
            options: opts
        ) { image, info in
            // Skip degraded (low-res placeholder) deliveries
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !degraded else { return }

            guard let nsImage = image,
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                completion(nil)
                return
            }

            // Run Vision request on background queue
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNGenerateImageFeaturePrintRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

                do {
                    try handler.perform([request])
                    let result = request.results?.first as? VNFeaturePrintObservation
                    completion(result)
                } catch {
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Duplicate Grouping

    /// Compare all fingerprints pairwise and group duplicates.
    /// This is O(n²) — only call on items that have fingerprints.
    static func findDuplicateGroups(
        items: [PhotoItem],
        fingerprints: [String: VNFeaturePrintObservation]
    ) -> [DuplicateGroup] {

        var assigned = Set<String>()     // IDs already in a group
        var groups   = [DuplicateGroup]()

        for i in 0..<items.count {
            let itemA = items[i]
            guard !assigned.contains(itemA.id),
                  let fpA = fingerprints[itemA.id] else { continue }

            var groupItems = [itemA]

            for j in (i + 1)..<items.count {
                let itemB = items[j]
                guard !assigned.contains(itemB.id),
                      let fpB = fingerprints[itemB.id] else { continue }

                var distance: Float = .greatestFiniteMagnitude
                do {
                    try fpA.computeDistance(&distance, to: fpB)
                } catch {
                    continue
                }

                if distance < threshold {
                    groupItems.append(itemB)
                    assigned.insert(itemB.id)
                }
            }

            // Only create a group if 2+ items match
            if groupItems.count > 1 {
                assigned.insert(itemA.id)
                groups.append(DuplicateGroup(id: UUID(), items: groupItems))
            }
        }

        return groups
    }
}
