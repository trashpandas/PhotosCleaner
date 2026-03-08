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
import Combine
import SwiftUI

/// Manages a macOS menu bar status item with a line art broom icon and a mini-menu
/// showing the current scan status, progress, and controls.
final class MenuBarManager: NSObject, ObservableObject {

    private var statusItem: NSStatusItem?
    private var vm: ScanViewModel?
    private var cancellables = Set<AnyCancellable>()

    // Menu items that update dynamically
    private var statusMenuItem: NSMenuItem?
    private var progressMenuItem: NSMenuItem?
    private var actionMenuItem: NSMenuItem?

    func setUp(with viewModel: ScanViewModel) {
        vm = viewModel
        createStatusItem()
        observeViewModel()
    }

    // MARK: - Status Item Creation

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }

        button.image = broomImage()
        button.image?.isTemplate = true  // Adapts to light/dark menu bar
        button.toolTip = "PhotosCleaner"

        buildMenu()
    }

    // MARK: - Line Art Broom Icon (18×18 pt)

    private func broomImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()

            // Broom handle — diagonal line from top-right toward bottom-left
            let handle = NSBezierPath()
            handle.lineWidth = 1.4
            handle.lineCapStyle = .round
            handle.move(to: NSPoint(x: 13.5, y: 16.0))
            handle.line(to: NSPoint(x: 6.0, y: 6.5))
            handle.stroke()

            // Broom head — fan of bristles at the bottom
            let bristleBase = NSPoint(x: 6.0, y: 6.5)

            let bristles = NSBezierPath()
            bristles.lineWidth = 1.2
            bristles.lineCapStyle = .round

            // Five bristle lines fanning out from the base
            let bristleEnds: [NSPoint] = [
                NSPoint(x: 1.5, y: 1.5),
                NSPoint(x: 3.5, y: 1.0),
                NSPoint(x: 5.5, y: 0.8),
                NSPoint(x: 7.5, y: 1.0),
                NSPoint(x: 9.5, y: 1.8),
            ]

            for end in bristleEnds {
                bristles.move(to: bristleBase)
                bristles.line(to: end)
            }
            bristles.stroke()

            // Small sweep lines (motion marks) near bristle tips
            let sweepMarks = NSBezierPath()
            sweepMarks.lineWidth = 0.8
            sweepMarks.lineCapStyle = .round

            sweepMarks.move(to: NSPoint(x: 11.0, y: 3.0))
            sweepMarks.line(to: NSPoint(x: 12.5, y: 2.5))

            sweepMarks.move(to: NSPoint(x: 11.5, y: 5.0))
            sweepMarks.line(to: NSPoint(x: 13.0, y: 4.5))

            sweepMarks.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu Construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // App title
        let titleItem = NSMenuItem(title: "PhotosCleaner", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        titleItem.attributedTitle = NSAttributedString(
            string: "PhotosCleaner",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(titleItem)

        menu.addItem(.separator())

        // Status line
        statusMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu.addItem(statusMenuItem!)

        // Progress line
        progressMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        progressMenuItem?.isEnabled = false
        progressMenuItem?.isHidden = true
        menu.addItem(progressMenuItem!)

        menu.addItem(.separator())

        // Action button — Start Scan / Stop Scan
        actionMenuItem = NSMenuItem(title: "Start Scan", action: #selector(actionTapped), keyEquivalent: "s")
        actionMenuItem?.target = self
        menu.addItem(actionMenuItem!)

        menu.addItem(.separator())

        // Show Window
        let showItem = NSMenuItem(title: "Show Window", action: #selector(showMainWindow), keyEquivalent: "o")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit PhotosCleaner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Observe ViewModel Changes

    private func observeViewModel() {
        guard let vm else { return }

        // Combine publishers for scan phase, status message, and progress
        vm.$scanPhase
            .combineLatest(vm.$statusMessage, vm.$progress)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, message, progress in
                self?.updateMenuItems(phase: phase, message: message, progress: progress)
            }
            .store(in: &cancellables)
    }

    private func updateMenuItems(phase: ScanPhase, message: String, progress: Double) {
        // Update status line
        let statusText: String
        switch phase {
        case .idle:
            statusText = "Ready to scan"
        case .complete:
            statusText = "Scan complete"
        case .cancelled:
            statusText = "Scan stopped"
        default:
            statusText = phase.rawValue
        }
        statusMenuItem?.title = statusText

        // Update progress line
        if phase != .idle && phase != .complete && phase != .cancelled {
            let pct = Int(progress * 100)
            let bar = progressBar(percent: pct)
            progressMenuItem?.title = "\(bar)  \(pct)%"
            progressMenuItem?.isHidden = false
        } else {
            progressMenuItem?.isHidden = true
        }

        // Update action button
        if phase != .idle && phase != .complete && phase != .cancelled {
            actionMenuItem?.title = "Stop Scan"
            actionMenuItem?.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
        } else {
            actionMenuItem?.title = "Start Scan"
            actionMenuItem?.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")
        }

        // Update status item button icon — add a dot overlay when scanning
        if let button = statusItem?.button {
            if phase != .idle && phase != .complete && phase != .cancelled {
                button.image = broomImageWithDot()
                button.image?.isTemplate = true
            } else {
                button.image = broomImage()
                button.image?.isTemplate = true
            }
        }
    }

    /// A simple ASCII-art progress bar for the menu.
    private func progressBar(percent: Int) -> String {
        let filled = percent / 10
        let empty  = 10 - filled
        return "[" + String(repeating: "=", count: filled) + String(repeating: " ", count: empty) + "]"
    }

    /// Broom icon with a small green dot in the corner (scanning indicator).
    private func broomImageWithDot() -> NSImage {
        let base = broomImage()
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)

            // Green dot at bottom-right corner
            NSColor.systemGreen.setFill()
            let dotRect = NSRect(x: size.width - 5, y: 0, width: 5, height: 5)
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = false  // Needs to be non-template to show the green dot
        return image
    }

    // MARK: - Actions

    @objc private func actionTapped() {
        guard let vm else { return }
        if vm.isScanning {
            vm.stopScan()
        } else {
            vm.startScan()
        }
    }

    @objc private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Teardown

    func remove() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        cancellables.removeAll()
    }
}
