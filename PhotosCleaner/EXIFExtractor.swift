import Foundation
import Photos
import CoreLocation
import ImageIO

// MARK: - EXIF Extractor

/// Extracts EXIF metadata from PHAsset resources using CGImageSource.
enum EXIFExtractor {

    // MARK: - Public API

    /// Extract EXIF metadata from a PHAsset.
    /// Uses `requestContentEditingInput` to get the full-size image URL,
    /// then reads EXIF via CGImageSource — fast, no pixel decoding needed.
    static func extract(from asset: PHAsset, completion: @escaping (EXIFData) -> Void) {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false
        options.canHandleAdjustmentData = { _ in false }

        asset.requestContentEditingInput(with: options) { input, _ in
            guard let url = input?.fullSizeImageURL else {
                completion(EXIFData())
                return
            }
            let exif = parseEXIF(from: url)
            completion(exif)
        }
    }

    /// Classify a photo's source type based on its PHAsset subtypes + EXIF data.
    static func classifySource(asset: PHAsset, exif: EXIFData) -> SourceClassification {
        // Check subtypes first (most reliable)
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            return .screenshot
        }
        if asset.mediaSubtypes.contains(.photoPanorama) {
            return .panorama
        }
        if asset.mediaSubtypes.contains(.photoHDR) {
            return .hdrPhoto
        }
        if asset.mediaSubtypes.contains(.photoLive) {
            return .livePhoto
        }
        if asset.mediaSubtypes.contains(.photoDepthEffect) {
            return .depthEffect
        }

        // Camera photo: has camera Make + Model in EXIF
        if exif.make != nil && exif.model != nil {
            return .cameraPhoto
        }

        // Has partial camera info — likely edited or processed
        if exif.make != nil || exif.model != nil {
            return .editedPhoto
        }

        // No camera EXIF at all — likely saved from the web or a messaging app
        if !exif.hasCameraInfo && exif.dateTimeOriginal == nil && exif.gps == nil {
            return .webSavedImage
        }

        return .unknown
    }

    // MARK: - EXIF Parsing

    /// Read EXIF from a file URL using ImageIO (no pixel decode — just metadata).
    private static func parseEXIF(from url: URL) -> EXIFData {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else {
            return EXIFData()
        }

        var exif = EXIFData()

        // ── TIFF dictionary (Make, Model, Orientation) ──────────────────────
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            exif.make        = tiff[kCGImagePropertyTIFFMake as String] as? String
            exif.model       = tiff[kCGImagePropertyTIFFModel as String] as? String
            exif.orientation = tiff[kCGImagePropertyTIFFOrientation as String] as? Int
        }

        // ── EXIF dictionary (Lens, DateTimeOriginal) ────────────────────────
        if let exifDict = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.lensModel = exifDict[kCGImagePropertyExifLensModel as String] as? String

            if let dateStr = exifDict[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                exif.dateTimeOriginal = Self.exifDateFormatter.date(from: dateStr)
            }
        }

        // ── GPS dictionary (Latitude, Longitude) ────────────────────────────
        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
               let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
                let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
                let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"

                let latitude  = lat * (latRef == "S" ? -1.0 : 1.0)
                let longitude = lon * (lonRef == "W" ? -1.0 : 1.0)

                exif.gps = GPSCoordinate(latitude: latitude, longitude: longitude)
            }
        }

        return exif
    }

    // MARK: - Date Formatter

    private static let exifDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    // MARK: - Reverse Geocoding

    /// Reverse-geocode a GPS coordinate into a human-readable location name.
    /// Uses Apple's CLGeocoder (rate-limited to ~50 req/min by the OS).
    static func reverseGeocode(_ coord: GPSCoordinate, completion: @escaping (String?) -> Void) {
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
            guard let place = placemarks?.first else {
                completion(nil)
                return
            }
            // Build a concise label: "City, Region" or "City, Country"
            let parts = [place.locality, place.administrativeArea ?? place.country]
                .compactMap { $0 }
            completion(parts.isEmpty ? nil : parts.joined(separator: ", "))
        }
    }
}
