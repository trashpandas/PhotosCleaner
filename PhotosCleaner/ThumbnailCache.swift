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

import AppKit

// MARK: - Thumbnail Cache

/// In-memory cache for thumbnail images loaded from the filesystem.
/// Critical for network drives where re-reading the same file is expensive.
/// Uses NSCache for automatic eviction under memory pressure.
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        // 200 MB total cost limit (estimated — each thumbnail is ~0.5–2 MB)
        cache.totalCostLimit = 200 * 1024 * 1024
        cache.countLimit = 500
    }

    // MARK: - Public API

    /// Get a thumbnail for a file URL, loading and caching if needed.
    /// Returns the thumbnail on the main queue via the completion handler.
    func thumbnail(for url: URL, targetSize: CGSize, completion: @escaping (NSImage?) -> Void) {
        let key = url.absoluteString as NSString

        // Check cache first
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        // Load and resize on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Use CGImageSource thumbnail generation for efficient loading
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
                kCGImageSourceCreateThumbnailWithTransform: true
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            // Estimate memory cost: width * height * 4 bytes per pixel
            let cost = cgImage.width * cgImage.height * 4
            self?.cache.setObject(thumbnail, forKey: key, cost: cost)

            DispatchQueue.main.async {
                completion(thumbnail)
            }
        }
    }

    /// Clear the entire cache (e.g., when starting a new scan).
    func clear() {
        cache.removeAllObjects()
    }
}
