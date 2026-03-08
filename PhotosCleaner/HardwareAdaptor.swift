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

// MARK: - Hardware Adaptor

/// Adapts concurrency levels and batch sizes to the current hardware.
/// Replaces hardcoded semaphore values with dynamic ones based on CPU cores and RAM.
enum HardwareAdaptor {

    /// Number of active CPU cores on this machine.
    static let cpuCores: Int = ProcessInfo.processInfo.activeProcessorCount

    /// Physical memory in bytes.
    static let physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// Physical memory in GB (rounded).
    static let memoryGB: Int = Int(physicalMemory / (1024 * 1024 * 1024))

    // MARK: - Concurrency Limits

    /// Concurrency for EXIF extraction (I/O-bound, moderate CPU).
    /// M1 Max (10 cores) → 5, M2 Air (8 cores) → 4, M1 (8 cores) → 4, Intel (4 cores) → 2
    static var exifConcurrency: Int {
        max(2, cpuCores / 2)
    }

    /// Concurrency for Vision fingerprint generation (GPU-heavy).
    /// M1 Max (10 cores) → 3, M2 Air (8 cores) → 2, M1 (8 cores) → 2
    static var fingerprintConcurrency: Int {
        max(2, cpuCores / 3)
    }

    /// Concurrency for filesystem image enumeration (I/O-bound, low CPU).
    /// Higher than EXIF since it's mostly waiting on disk/network.
    static var enumerationConcurrency: Int {
        max(4, cpuCores)
    }

    // MARK: - Description

    /// Human-readable description of detected hardware (for logging / About).
    static var description: String {
        "\(cpuCores) CPU cores, \(memoryGB) GB RAM"
    }
}
