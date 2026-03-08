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

/// Side-by-side review of duplicate photo groups.
struct DuplicateReviewView: View {

    @ObservedObject var vm: ScanViewModel
    @Binding var isPresented: Bool

    @State private var groupIndex = 0
    @State private var loadedImages = [String: NSImage]()
    @State private var pendingDeletes = [PhotoItem]()
    @State private var showBatchResult    = false
    @State private var batchResultMessage = ""
    @State private var batchSucceeded     = false

    private var currentGroup: DuplicateGroup? {
        guard groupIndex < vm.duplicateGroups.count else { return nil }
        return vm.duplicateGroups[groupIndex]
    }

    private var isLastGroup: Bool {
        groupIndex >= vm.duplicateGroups.count - 1
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let group = currentGroup {
                groupContent(group)
            } else {
                completionView
            }
        }
        .frame(minWidth: 800, minHeight: 620)
        .onChange(of: groupIndex) { _ in
            loadedImages = [:]
            loadImagesForCurrentGroup()
        }
        .onAppear {
            loadImagesForCurrentGroup()
        }
    }

    // MARK: - Header

    var header: some View {
        HStack {
            Text("Review Duplicate Groups")
                .font(.headline)
            Spacer()
            if !vm.duplicateGroups.isEmpty {
                Text("Group \(groupIndex + 1) of \(vm.duplicateGroups.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Button("Done") {
                if pendingDeletes.isEmpty {
                    isPresented = false
                } else {
                    // Jump to completion to process batch
                    groupIndex = vm.duplicateGroups.count
                }
            }
            .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Group Content

    func groupContent(_ group: DuplicateGroup) -> some View {
        VStack(spacing: 12) {
            // Photo grid
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(group.items) { item in
                        VStack(spacing: 8) {
                            // Image
                            ZStack {
                                Color(NSColor.controlBackgroundColor)
                                if let img = loadedImages[item.id] {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .padding(4)
                                } else {
                                    ProgressView()
                                }
                            }
                            .frame(width: 280, height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            // Best badge
                            if item.id == group.bestItem.id {
                                Label("Best Quality", systemImage: "star.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.yellow)
                            }

                            // Metadata
                            VStack(spacing: 2) {
                                Text(item.filename)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text("\(item.width) x \(item.height) px")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(item.dateString.isEmpty ? "Unknown date" : item.dateString)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if let model = item.exif.model {
                                    Text(model)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            Divider()

            // Actions
            HStack(spacing: 14) {
                Button {
                    navigateGroup(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(groupIndex == 0)

                Spacer()

                // Keep best, delete rest
                Button {
                    let group = vm.duplicateGroups[groupIndex]
                    let toDelete = group.items.filter { $0.id != group.bestItem.id }
                    pendingDeletes.append(contentsOf: toDelete)
                    navigateGroup(1)
                } label: {
                    Label("Keep Best, Delete \(group.removableCount) Others", systemImage: "star.fill")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                // Keep all
                Button {
                    navigateGroup(1)
                } label: {
                    Label("Keep All", systemImage: "checkmark")
                }
                .buttonStyle(.bordered)

                // Delete all
                Button(role: .destructive) {
                    let group = vm.duplicateGroups[groupIndex]
                    pendingDeletes.append(contentsOf: group.items)
                    navigateGroup(1)
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Spacer()

                Button {
                    navigateGroup(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(isLastGroup)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Completion View

    var completionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("Duplicate Review Complete!")
                .font(.title.bold())

            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "trash").foregroundColor(.red).frame(width: 20)
                    Text("Queued for deletion")
                    Spacer()
                    Text("\(pendingDeletes.count)")
                        .font(.body.monospacedDigit().bold())
                }
                .frame(width: 280)
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if !pendingDeletes.isEmpty {
                VStack(spacing: 8) {
                    Text("\(pendingDeletes.count) photos queued for deletion.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Photos will ask you to confirm once.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        processBatchDelete()
                    } label: {
                        Label("Delete \(pendingDeletes.count) Photos Now", systemImage: "trash.fill")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(vm.batchProcessing)

                    if vm.batchProcessing {
                        ProgressView("Processing…")
                            .font(.caption)
                    }
                }
            }

            if showBatchResult {
                Label(batchResultMessage,
                      systemImage: batchSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(batchSucceeded ? .green : .red)
            }

            Button("Close") { isPresented = false }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
        }
        .padding(48)
    }

    // MARK: - Helpers

    func navigateGroup(_ delta: Int) {
        let next = groupIndex + delta
        if next >= 0 && next <= vm.duplicateGroups.count {
            groupIndex = next
        }
    }

    func loadImagesForCurrentGroup() {
        guard let group = currentGroup else { return }
        for item in group.items {
            guard loadedImages[item.id] == nil else { continue }
            let results = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
            guard let asset = results.firstObject else { continue }

            let opts = PHImageRequestOptions()
            opts.deliveryMode          = .opportunistic
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous          = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 560, height: 440),
                contentMode: .aspectFit,
                options: opts
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let img = image {
                    DispatchQueue.main.async {
                        self.loadedImages[item.id] = img
                    }
                }
                _ = degraded  // suppress unused warning
            }
        }
    }

    func processBatchDelete() {
        let ids = pendingDeletes.map { $0.id }
        guard !ids.isEmpty else { return }

        vm.batchProcessing = true
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { _, error in
            DispatchQueue.main.async {
                vm.batchProcessing = false
                if let error {
                    batchResultMessage = "Error: \(error.localizedDescription)"
                    batchSucceeded     = false
                } else {
                    batchResultMessage = "Done! \(ids.count) items moved to Recently Deleted."
                    batchSucceeded     = true
                    pendingDeletes     = []
                }
                showBatchResult = true
            }
        }
    }
}
