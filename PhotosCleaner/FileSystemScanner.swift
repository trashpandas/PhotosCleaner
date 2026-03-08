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
import ImageIO

// MARK: - File System Scanner

/// Recursively enumerates image files in a folder and extracts basic metadata.
enum FileSystemScanner {

    /// Supported image file extensions.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif",
        "gif", "bmp", "webp", "raw", "cr2", "nef", "arw", "dng"
    ]

    // MARK: - Enumerate Images

    /// Recursively find all image files in `folderURL`.
    /// Skips hidden files and directories (those starting with `.`).
    static func enumerateImages(in folderURL: URL) -> [URL] {
        var results = [URL]()

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .nameKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return results
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }

            // Double-check it's a regular file
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true {
                results.append(fileURL)
            }
        }

        return results
    }

    // MARK: - Load Image Metadata

    /// Read pixel dimensions and file dates without decoding pixels.
    /// Uses CGImageSource for width/height (fast, metadata-only).
    static func loadImageMetadata(from url: URL) -> (width: Int, height: Int, date: Date?) {
        var width  = 0
        var height = 0
        var date: Date? = nil

        // Read pixel dimensions from image header
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            width  = props[kCGImagePropertyPixelWidth as String]  as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        }

        // Use file modification date as fallback
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            date = attrs[.modificationDate] as? Date
                ?? attrs[.creationDate] as? Date
        }

        return (width, height, date)
    }

    // MARK: - Basic Classification

    /// Classify a filesystem image based on filename, dimensions, and aspect ratio.
    /// Returns an array of reason strings (same format as ScanViewModel.classify).
    static func classifyFileSystemImage(filename: String, width: Int, height: Int) -> [String] {
        var reasons = [String]()

        // Screenshot detection via common filename patterns
        let lower = filename.lowercased()
        if lower.hasPrefix("screenshot") ||
           lower.contains("screen shot") ||
           lower.hasPrefix("scr_") ||
           lower.contains("截屏") ||       // Chinese
           lower.contains("bildschirmfoto") // German
        {
            return ["screenshot"]
        }

        // Unusual aspect ratio
        if height > 0 {
            let ratio = Double(width) / Double(height)
            if ratio < 0.5 || ratio > 2.5 {
                reasons.append("unusual aspect ratio (\(width)×\(height))")
            }
        }

        // Very small image
        if width > 0 && height > 0 && (width < 200 || height < 200) {
            reasons.append("very small (\(width)×\(height)px)")
        }

        return reasons
    }
}
