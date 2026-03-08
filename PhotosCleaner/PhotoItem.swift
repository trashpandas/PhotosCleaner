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

// MARK: - Photo Source

/// Whether the photo came from the Apple Photos library or the filesystem.
enum PhotoSource: String {
    case photoKit   = "Photos Library"
    case fileSystem = "Folder"
}

// MARK: - Source Classification

/// How the photo was captured / where it came from.
enum SourceClassification: String, CaseIterable {
    case cameraPhoto   = "Camera Photo"
    case editedPhoto   = "Edited Photo"
    case webSavedImage = "Web / Saved Image"
    case screenshot    = "Screenshot"
    case panorama      = "Panorama"
    case hdrPhoto      = "HDR Photo"
    case livePhoto     = "Live Photo"
    case depthEffect   = "Depth Effect"
    case unknown       = "Unknown"
}

// MARK: - Content Category

/// High-level content category assigned by metadata analysis.
enum ContentCategory: String, CaseIterable {
    case screenshots   = "Screenshots"
    case webImages     = "Web / Saved Images"
    case cameraPhotos  = "Camera Photos"
    case duplicates    = "Duplicates"
    case panoramas     = "Panoramas"
    case livePhotos    = "Live Photos"
    case hdrPhotos     = "HDR Photos"
    case smallImages   = "Small / Thumbnails"
    case unusualRatio  = "Unusual Aspect Ratio"
    case uncategorized = "Uncategorized"
}

// MARK: - GPS Coordinate

struct GPSCoordinate {
    let latitude: Double
    let longitude: Double
    var locationName: String? = nil
}

// MARK: - EXIF Data

/// Parsed EXIF metadata from a photo's image resource.
struct EXIFData {
    var make: String?            = nil   // Camera manufacturer
    var model: String?           = nil   // Camera model
    var lensModel: String?       = nil   // Lens description
    var dateTimeOriginal: Date?  = nil   // Capture timestamp from EXIF
    var gps: GPSCoordinate?      = nil   // GPS coordinates
    var orientation: Int?        = nil   // EXIF orientation tag

    /// True if this EXIF data contains camera-specific fields.
    var hasCameraInfo: Bool {
        make != nil || model != nil
    }
}

// MARK: - Photo Item

/// A photo in the library with all v2 metadata.
struct PhotoItem: Identifiable {
    let id: String          // PHAsset.localIdentifier
    let filename: String
    let date: Date?
    let width: Int
    let height: Int
    let reasons: [String]

    // v2: EXIF metadata
    var exif: EXIFData = EXIFData()

    // v2: Classification
    var sourceClassification: SourceClassification = .unknown
    var contentCategory: ContentCategory = .uncategorized

    // v2: Duplicate detection
    var duplicateGroupID: UUID? = nil
    var isDuplicate: Bool = false

    // v3: Source tracking
    var photoSource: PhotoSource = .photoKit
    var fileURL: URL? = nil

    // MARK: Computed

    var reasonSummary: String {
        reasons.joined(separator: ", ")
    }

    var dateString: String {
        guard let date else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    var cameraDescription: String {
        if let make = exif.make, let model = exif.model {
            // Many models already include the make (e.g. "Apple iPhone 15")
            if model.lowercased().contains(make.lowercased()) {
                return model
            }
            return "\(make) \(model)"
        }
        return exif.model ?? exif.make ?? "Unknown"
    }

    var locationDescription: String {
        exif.gps?.locationName ?? "Unknown Location"
    }
}

// MARK: - Tally Rows

/// A row in the breakdown-by-reason results table.
struct TallyRow: Identifiable {
    let id = UUID()
    let reason: String
    let count: Int
}

/// Source classification breakdown row.
struct SourceTally: Identifiable {
    let id = UUID()
    let source: SourceClassification
    let count: Int
}

/// Category breakdown row.
struct CategoryTally: Identifiable {
    let id = UUID()
    let category: ContentCategory
    let count: Int
}

// MARK: - Duplicate Group

/// A group of visually similar / duplicate photos.
struct DuplicateGroup: Identifiable {
    let id: UUID
    var items: [PhotoItem]

    /// The "best" item — highest resolution.
    var bestItem: PhotoItem {
        items.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) ?? items[0]
    }

    /// Number of items that could be removed (all except the best).
    var removableCount: Int { max(items.count - 1, 0) }
}
