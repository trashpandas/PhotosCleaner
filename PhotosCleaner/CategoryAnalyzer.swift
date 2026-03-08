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

// MARK: - Category Analyzer

/// Assigns content categories and builds groupings from metadata (no ML).
enum CategoryAnalyzer {

    // MARK: - Categorize Single Item

    /// Assign a content category based on source classification, reasons, and metadata.
    static func categorize(_ item: PhotoItem) -> ContentCategory {
        // Priority order — most specific first

        if item.sourceClassification == .screenshot {
            return .screenshots
        }
        if item.isDuplicate {
            return .duplicates
        }
        if item.sourceClassification == .webSavedImage {
            return .webImages
        }
        if item.sourceClassification == .panorama {
            return .panoramas
        }
        if item.sourceClassification == .livePhoto {
            return .livePhotos
        }
        if item.sourceClassification == .hdrPhoto {
            return .hdrPhotos
        }
        if item.reasons.contains(where: { $0.hasPrefix("very small") }) {
            return .smallImages
        }
        if item.reasons.contains(where: { $0.hasPrefix("unusual aspect") }) {
            return .unusualRatio
        }
        if item.sourceClassification == .cameraPhoto || item.sourceClassification == .editedPhoto {
            return .cameraPhotos
        }

        return .uncategorized
    }

    // MARK: - Batch Categorize

    /// Categorize all items and return updated items + tallies.
    static func categorizeAll(_ items: [PhotoItem]) -> (items: [PhotoItem], tallies: [CategoryTally]) {
        var updated = items
        var counts  = [ContentCategory: Int]()

        for i in updated.indices {
            let cat = categorize(updated[i])
            updated[i].contentCategory = cat
            counts[cat, default: 0] += 1
        }

        let tallies = counts
            .sorted { $0.value > $1.value }
            .map { CategoryTally(category: $0.key, count: $0.value) }

        return (updated, tallies)
    }

    // MARK: - Source Classification Tallies

    /// Build a breakdown of source classifications.
    static func sourceBreakdown(_ items: [PhotoItem]) -> [SourceTally] {
        var counts = [SourceClassification: Int]()
        for item in items {
            counts[item.sourceClassification, default: 0] += 1
        }
        return counts
            .sorted { $0.value > $1.value }
            .map { SourceTally(source: $0.key, count: $0.value) }
    }

    // MARK: - Camera Breakdown

    /// Group items by camera make/model.
    static func cameraBreakdown(_ items: [PhotoItem]) -> [(camera: String, count: Int)] {
        var counts = [String: Int]()
        for item in items {
            let key = item.cameraDescription
            counts[key, default: 0] += 1
        }
        return counts
            .sorted { $0.value > $1.value }
            .map { (camera: $0.key, count: $0.value) }
    }

    // MARK: - Location Grouping

    /// Group items by location name (requires reverse-geocoded GPS).
    /// Only includes items where locationName has actually been geocoded.
    static func locationBreakdown(_ items: [PhotoItem]) -> [(location: String, count: Int)] {
        var counts = [String: Int]()
        for item in items {
            if let name = item.exif.gps?.locationName {
                counts[name, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .map { (location: $0.key, count: $0.value) }
    }

    // MARK: - Burst Detection

    /// Find sequences of photos taken within `interval` seconds of each other.
    static func detectBursts(_ items: [PhotoItem], interval: TimeInterval = 2.0) -> [[PhotoItem]] {
        let sorted = items
            .filter { $0.date != nil }
            .sorted { $0.date! < $1.date! }

        guard sorted.count > 1 else { return [] }

        var bursts       = [[PhotoItem]]()
        var currentBurst = [sorted[0]]

        for i in 1..<sorted.count {
            let gap = sorted[i].date!.timeIntervalSince(sorted[i - 1].date!)
            if gap <= interval {
                currentBurst.append(sorted[i])
            } else {
                if currentBurst.count > 1 {
                    bursts.append(currentBurst)
                }
                currentBurst = [sorted[i]]
            }
        }
        if currentBurst.count > 1 {
            bursts.append(currentBurst)
        }

        return bursts
    }
}
