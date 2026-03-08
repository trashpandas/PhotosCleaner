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

import SwiftUI
import Photos
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var vm = ScanViewModel()

    // Alert state
    @State private var alertTitle   = ""
    @State private var alertMessage = ""
    @State private var showingAlert = false

    // CSV export
    @State private var showExportPanel = false

    // Review sheets
    @State private var showingReview          = false
    @State private var showingDuplicateReview = false

    // Tab selection
    @State private var selectedTab = "overview"

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            scanControlBar
            Divider()

            if vm.scanPhase == .idle {
                idleView
            } else if vm.isScanning {
                scanningView
            } else {
                resultsView
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 600, idealHeight: 680)
        .alert(alertTitle, isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            vm.checkAuthorization()
        }
        .sheet(isPresented: $showingReview) {
            ReviewView(vm: vm, isPresented: $showingReview)
        }
        .sheet(isPresented: $showingDuplicateReview) {
            DuplicateReviewView(vm: vm, isPresented: $showingDuplicateReview)
        }
        .background(
            ExportHelper(isPresented: $showExportPanel, content: vm.csvContent()) { savedURL in
                if let url = savedURL {
                    showAlert("Saved", "Report saved to \(url.lastPathComponent).")
                }
            }
        )
    }

    // MARK: - Header

    var headerBar: some View {
        HStack {
            Label("Photos Library Cleaner", systemImage: "photo.stack.fill")
                .font(.title3.bold())
                .foregroundColor(.white)
            Spacer()
            Text("v2.0")
                .font(.caption)
                .foregroundColor(Color.white.opacity(0.5))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13))
    }

    // MARK: - Scan Control Bar

    var scanControlBar: some View {
        HStack(spacing: 14) {
            Button {
                vm.startScan()
            } label: {
                Label(scanLabel, systemImage: "play.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isScanning)

            Toggle(isOn: $vm.skipFingerprinting) {
                Label("Quick Scan", systemImage: "hare.fill")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Skip duplicate detection for a faster scan")
            .disabled(vm.isScanning)

            Spacer()

            if let err = vm.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Idle View

    var idleView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("Find screenshots, memes, duplicates, and other\nnon-photo items in your Photos library.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("Click Start Scan to begin.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Scanning View

    var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text(vm.scanPhase.rawValue)
                .font(.headline)

            Text(vm.statusMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            ProgressView(value: vm.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 400)

            if vm.totalCount > 0 {
                Text("\(vm.scannedCount.formatted()) / \(vm.totalCount.formatted())")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    // MARK: - Results View (tabs)

    var resultsView: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Overview").tag("overview")
                Text("Categories").tag("categories")
                Text("Duplicates (\(vm.duplicateGroups.count))").tag("duplicates")
                Text("Sources").tag("sources")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            switch selectedTab {
            case "overview":    overviewTab
            case "categories":  categoriesTab
            case "duplicates":  duplicatesTab
            case "sources":     sourcesTab
            default:            overviewTab
            }
        }
    }

    // MARK: - Overview Tab

    var overviewTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(vm.statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.green)

                        HStack(spacing: 24) {
                            statBadge(label: "Total Photos", value: vm.allItems.count, color: .blue)
                            statBadge(label: "Flagged", value: vm.flaggedItems.count, color: .orange)
                            statBadge(label: "Duplicates", value: vm.duplicateGroups.count, color: .red)
                            statBadge(label: "Web Images",
                                      value: vm.allItems.filter { $0.sourceClassification == .webSavedImage }.count,
                                      color: .purple)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    Text("Summary")
                }

                if !vm.tallyRows.isEmpty {
                    GroupBox {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Detection reason")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("Items found")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 100, alignment: .center)
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)

                            Divider()

                            ForEach(vm.tallyRows) { row in
                                HStack {
                                    Text(row.reason)
                                        .font(.subheadline)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(row.count.formatted())
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundColor(row.count > 100 ? .orange : .primary)
                                        .frame(width: 100, alignment: .center)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                            }
                        }
                    } label: {
                        Text("Flagged Items")
                    }
                }

                actionButtons
            }
            .padding(20)
        }
    }

    // MARK: - Categories Tab

    var categoriesTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                if vm.categoryTallies.isEmpty {
                    Text("No category data available.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(vm.categoryTallies) { tally in
                        HStack {
                            Image(systemName: iconForCategory(tally.category))
                                .foregroundColor(colorForCategory(tally.category))
                                .frame(width: 24)
                            Text(tally.category.rawValue)
                                .font(.subheadline)
                            Spacer()
                            Text(tally.count.formatted())
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundColor(.secondary)

                            let pct = vm.allItems.isEmpty ? 0.0 : Double(tally.count) / Double(vm.allItems.count)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(colorForCategory(tally.category).opacity(0.3))
                                .frame(width: max(pct * 200, 2), height: 16)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        Divider().padding(.horizontal, 20)
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: - Duplicates Tab

    var duplicatesTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                if vm.duplicateGroups.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: vm.skipFingerprinting ? "hare.fill" : "checkmark.seal.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(vm.skipFingerprinting
                             ? "Duplicate detection was skipped (Quick Scan mode).\nRun a full scan to detect duplicates."
                             : "No duplicate photos found!")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    HStack {
                        Text("\(vm.duplicateGroups.count) duplicate groups found")
                            .font(.headline)
                        Spacer()
                        Button {
                            showingDuplicateReview = true
                        } label: {
                            Label("Review Duplicates", systemImage: "eye")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }
                    .padding(.horizontal, 20)

                    ForEach(vm.duplicateGroups) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(group.items.count) similar photos")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text("Best: \(group.bestItem.width)x\(group.bestItem.height)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                ForEach(group.items) { item in
                                    HStack(spacing: 8) {
                                        Image(systemName: item.id == group.bestItem.id ? "star.fill" : "doc")
                                            .foregroundColor(item.id == group.bestItem.id ? .yellow : .secondary)
                                            .frame(width: 16)
                                        Text(item.filename)
                                            .font(.caption)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(item.width)x\(item.height)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(item.dateString)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: - Sources Tab

    var sourcesTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !vm.sourceTallies.isEmpty {
                    GroupBox("Photo Sources") {
                        VStack(spacing: 0) {
                            ForEach(vm.sourceTallies) { tally in
                                HStack {
                                    Image(systemName: iconForSource(tally.source))
                                        .foregroundColor(colorForSource(tally.source))
                                        .frame(width: 24)
                                    Text(tally.source.rawValue)
                                        .font(.subheadline)
                                    Spacer()
                                    Text(tally.count.formatted())
                                        .font(.subheadline.monospacedDigit().bold())

                                    let pct = vm.allItems.isEmpty ? 0.0 : Double(tally.count) / Double(vm.allItems.count)
                                    Text(String(format: "%.1f%%", pct * 100))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 50, alignment: .trailing)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !vm.cameraBreakdown.isEmpty {
                    GroupBox("Cameras") {
                        VStack(spacing: 0) {
                            ForEach(Array(vm.cameraBreakdown.prefix(15).enumerated()), id: \.offset) { _, entry in
                                HStack {
                                    Image(systemName: "camera")
                                        .foregroundColor(.secondary)
                                        .frame(width: 24)
                                    Text(entry.camera)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(entry.count.formatted())
                                        .font(.subheadline.monospacedDigit().bold())
                                }
                                .padding(.vertical, 3)
                            }
                            if vm.cameraBreakdown.count > 15 {
                                Text("…and \(vm.cameraBreakdown.count - 15) more")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !vm.locationBreakdown.isEmpty {
                    GroupBox("Locations (GPS)") {
                        VStack(spacing: 0) {
                            ForEach(Array(vm.locationBreakdown.prefix(15).enumerated()), id: \.offset) { _, entry in
                                HStack {
                                    Image(systemName: "mappin")
                                        .foregroundColor(.red)
                                        .frame(width: 24)
                                    Text(entry.location)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(entry.count.formatted())
                                        .font(.subheadline.monospacedDigit().bold())
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Action Buttons

    var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                vm.startReview()
                showingReview = true
            } label: {
                Label("Review Items", systemImage: "eye")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(vm.flaggedItems.isEmpty)

            if !vm.duplicateGroups.isEmpty {
                Button {
                    showingDuplicateReview = true
                } label: {
                    Label("Review Duplicates", systemImage: "doc.on.doc")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Button {
                vm.createAlbum { result in
                    switch result {
                    case .success(let count):
                        showAlert("Album Created",
                                  "Added \(count.formatted()) items to \"\(ScanViewModel.albumName)\" in Photos.")
                    case .failure(let err):
                        showAlert("Could Not Create Album", err.localizedDescription)
                    }
                }
            } label: {
                Label("Create Review Album", systemImage: "folder.badge.plus")
            }
            .disabled(vm.flaggedItems.isEmpty)

            Button {
                showExportPanel = true
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(vm.allItems.isEmpty)

            Spacer()
        }
    }

    // MARK: - Helpers

    var scanLabel: String {
        if vm.isScanning { return "Scanning…" }
        if vm.scanComplete { return "Scan Again" }
        return "Start Scan"
    }

    func showAlert(_ title: String, _ message: String) {
        alertTitle   = title
        alertMessage = message
        showingAlert = true
    }

    func statBadge(label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.title2.bold().monospacedDigit())
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    func iconForCategory(_ cat: ContentCategory) -> String {
        switch cat {
        case .screenshots:   return "camera.viewfinder"
        case .webImages:     return "globe"
        case .cameraPhotos:  return "camera"
        case .duplicates:    return "doc.on.doc"
        case .panoramas:     return "pano"
        case .livePhotos:    return "livephoto"
        case .hdrPhotos:     return "camera.filters"
        case .smallImages:   return "photo"
        case .unusualRatio:  return "aspectratio"
        case .uncategorized: return "questionmark.circle"
        }
    }

    func colorForCategory(_ cat: ContentCategory) -> Color {
        switch cat {
        case .screenshots:   return .orange
        case .webImages:     return .purple
        case .cameraPhotos:  return .green
        case .duplicates:    return .red
        case .panoramas:     return .blue
        case .livePhotos:    return .cyan
        case .hdrPhotos:     return .yellow
        case .smallImages:   return .gray
        case .unusualRatio:  return .pink
        case .uncategorized: return .secondary
        }
    }

    func iconForSource(_ src: SourceClassification) -> String {
        switch src {
        case .cameraPhoto:   return "camera.fill"
        case .editedPhoto:   return "wand.and.stars"
        case .webSavedImage: return "globe"
        case .screenshot:    return "camera.viewfinder"
        case .panorama:      return "pano.fill"
        case .hdrPhoto:      return "camera.filters"
        case .livePhoto:     return "livephoto"
        case .depthEffect:   return "cube"
        case .unknown:       return "questionmark.circle"
        }
    }

    func colorForSource(_ src: SourceClassification) -> Color {
        switch src {
        case .cameraPhoto:   return .green
        case .editedPhoto:   return .blue
        case .webSavedImage: return .purple
        case .screenshot:    return .orange
        case .panorama:      return .cyan
        case .hdrPhoto:      return .yellow
        case .livePhoto:     return .teal
        case .depthEffect:   return .indigo
        case .unknown:       return .secondary
        }
    }
}

// MARK: - Export Helper

private struct ExportHelper: NSViewRepresentable {

    @Binding var isPresented: Bool
    let content: String
    let onSave: (URL?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented else { return }
        isPresented = false

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "photos_report.csv"
        panel.allowedContentTypes  = [.commaSeparatedText]
        panel.directoryURL         = FileManager.default.urls(
            for: .desktopDirectory, in: .userDomainMask).first

        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else {
                    onSave(nil)
                    return
                }
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    onSave(url)
                } catch {
                    onSave(nil)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
