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

struct ReviewView: View {

    @ObservedObject var vm: ScanViewModel
    @Binding var isPresented: Bool

    // Image loading
    @State private var loadedImage: NSImage?    = nil
    @State private var imageLoading: Bool       = false
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    // Album input
    @State private var albumNameInput:   String = ""
    @State private var showingAlbumInput: Bool  = false

    // Action state
    @State private var isProcessing:    Bool = false
    @State private var confirmingDelete: Bool = false
    @State private var errorText:       String? = nil

    // Speed mode — skips delete confirmation dialog
    @State private var speedMode: Bool = false

    // Batch result (shown on completion screen)
    @State private var showBatchResult:    Bool   = false
    @State private var batchResultMessage: String = ""
    @State private var batchSucceeded:     Bool   = false

    // Manual completion (user clicked "Done" before reviewing all)
    @State private var manualComplete:     Bool   = false

    // MARK: - Derived

    var currentItem: PhotoItem? {
        guard !vm.reviewQueue.isEmpty,
              vm.reviewIndex < vm.reviewQueue.count else { return nil }
        return vm.reviewQueue[vm.reviewIndex]
    }

    var isComplete: Bool { vm.reviewQueue.isEmpty || manualComplete }

    var progressText: String {
        let remaining = vm.reviewQueue.count
        let done = vm.reviewDeleted + vm.reviewKept + vm.reviewMoved
        return "\(vm.reviewIndex + 1) of \(remaining)  •  \(done) decided"
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isComplete {
                completionView
            } else {
                reviewContent
            }
        }
        .frame(minWidth: 720, minHeight: 600)
    }

    // MARK: - Main Review Layout

    var reviewContent: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            photoArea
            Divider()
            metadataBar
            Divider()
            if showingAlbumInput { albumInputBar; Divider() }
            if let err = errorText {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }
            actionBar
        }
        .onChange(of: vm.reviewIndex)   { _ in loadImage() }
        .onChange(of: vm.reviewQueue.count) { _ in if !isComplete { loadImage() } }
        .onAppear { loadImage() }
    }

    // MARK: - Header

    var headerBar: some View {
        HStack(spacing: 14) {
            Text("Review Flagged Items")
                .font(.headline)

            Toggle(isOn: $speedMode) {
                Label("Speed Mode", systemImage: "hare.fill")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Skip delete confirmation — one click to delete")

            Spacer()

            Text(progressText)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Done") {
                if vm.pendingDeletions.isEmpty {
                    isPresented = false
                } else {
                    manualComplete = true
                }
            }
            .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Photo Preview

    var photoArea: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)

            if imageLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let img = loadedImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    .transition(.opacity.animation(.easeIn(duration: 0.15)))
            } else {
                Image(systemName: "photo.slash")
                    .font(.system(size: 56))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
    }

    // MARK: - Metadata Bar

    var metadataBar: some View {
        HStack(alignment: .top, spacing: 24) {
            if let item = currentItem {
                // Left: file details
                VStack(alignment: .leading, spacing: 4) {
                    Label(item.filename, systemImage: "doc.fill")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Label(item.dateString.isEmpty ? "Unknown date" : item.dateString,
                          systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Label("\(item.width) × \(item.height) px",
                          systemImage: "aspectratio")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    // v2: Camera info
                    if item.exif.hasCameraInfo {
                        Label(item.cameraDescription, systemImage: "camera")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Right: tags
                VStack(alignment: .trailing, spacing: 4) {
                    // Source classification tag
                    if item.sourceClassification != .unknown {
                        Text(item.sourceClassification.rawValue)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    // Reason tags
                    HStack(spacing: 6) {
                        ForEach(item.reasons, id: \.self) { reason in
                            Text(reason)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Album Name Input

    var albumInputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .foregroundColor(.secondary)
            TextField("Album name", text: $albumNameInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit { performMove() }
            Button("Move") { performMove() }
                .buttonStyle(.borderedProminent)
                .disabled(albumNameInput.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing)
            Button("Cancel") {
                showingAlbumInput = false
                albumNameInput    = ""
            }
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06))
    }

    // MARK: - Action Bar

    var actionBar: some View {
        HStack(spacing: 14) {

            // ← Previous
            Button {
                navigate(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .disabled(vm.reviewIndex == 0 || isProcessing)
            .help("Previous item")

            Spacer()

            // 🗑 Delete
            Button(role: .destructive) {
                if speedMode {
                    performDelete()
                } else {
                    confirmingDelete = true
                }
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(minWidth: 88)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isProcessing)
            .help(speedMode
                  ? "Delete immediately (⌘⌫) — Speed Mode ON"
                  : "Move to Recently Deleted (⌘⌫)")
            .keyboardShortcut(.delete, modifiers: .command)
            .confirmationDialog(
                "Delete \"\(currentItem?.filename ?? "this photo")\"?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It will be moved to Recently Deleted in Photos.")
            }

            // ❤️ Keep
            Button { performKeep() } label: {
                Label("Keep", systemImage: "heart.fill")
                    .frame(minWidth: 88)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(isProcessing)
            .help("Add to \"Reviewed: Keep\" album (K)")
            .keyboardShortcut("k", modifiers: [])

            // 📁 Move to Album
            Button {
                withAnimation { showingAlbumInput.toggle() }
            } label: {
                Label("Move to Album…", systemImage: "folder.badge.plus")
                    .frame(minWidth: 116)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)
            .help("Add to a specific album")

            Spacer()

            // → Next
            Button {
                navigate(1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .disabled(vm.reviewIndex >= vm.reviewQueue.count - 1 || isProcessing)
            .help("Next item (peek without deciding)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Completion View

    var completionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("Review Complete!")
                .font(.title.bold())

            VStack(spacing: 8) {
                statRow(icon: "trash",       color: .red,    label: "Queued for deletion", count: vm.reviewDeleted)
                statRow(icon: "heart.fill",  color: .green,  label: "Kept",                count: vm.reviewKept)
                statRow(icon: "folder.fill", color: .blue,   label: "Moved to album",      count: vm.reviewMoved)
                if manualComplete && !vm.reviewQueue.isEmpty {
                    statRow(icon: "forward.fill", color: .secondary, label: "Skipped (still in queue)", count: vm.reviewQueue.count)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Pending deletions batch action
            if !vm.pendingDeletions.isEmpty {
                VStack(spacing: 8) {
                    Text("\(vm.pendingDeletions.count.formatted()) photos are queued for deletion.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Photos will ask you to confirm once — just one click.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        vm.processPendingDeletions { result in
                            switch result {
                            case .success(let count):
                                batchResultMessage = "Done! \(count.formatted()) items moved to Recently Deleted."
                                batchSucceeded     = true
                            case .failure(let err):
                                batchResultMessage = "Error: \(err.localizedDescription)"
                                batchSucceeded     = false
                            }
                            showBatchResult = true
                        }
                    } label: {
                        Label("Delete \(vm.pendingDeletions.count.formatted()) Photos Now",
                              systemImage: "trash.fill")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(vm.batchProcessing)
                    .controlSize(.large)

                    if vm.batchProcessing {
                        ProgressView("Processing…")
                            .font(.caption)
                    }
                }
                .padding(.top, 4)
            }

            // Batch result feedback
            if showBatchResult {
                Label(batchResultMessage,
                      systemImage: batchSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(batchSucceeded ? .green : .red)
            }

            // Footnote
            if vm.pendingDeletions.isEmpty {
                Text("All done! Items in Recently Deleted will be permanently removed after 30 days.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Close") { isPresented = false }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
        }
        .padding(48)
        .frame(minWidth: 440, minHeight: 420)
    }

    func statRow(icon: String, color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
            Spacer()
            Text("\(count.formatted())")
                .font(.body.monospacedDigit().bold())
        }
        .frame(width: 280)
    }

    // MARK: - Image Loading

    func loadImage() {
        // Cancel any in-flight request
        if requestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
            requestID = PHInvalidImageRequestID
        }

        guard let item = currentItem else { return }

        loadedImage   = nil
        imageLoading  = true

        let results = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
        guard let asset = results.firstObject else {
            imageLoading = false
            return
        }

        let opts = PHImageRequestOptions()
        opts.deliveryMode          = .opportunistic   // low-res first, then full
        opts.isNetworkAccessAllowed = true            // fetch from iCloud if needed
        opts.isSynchronous          = false

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 700, height: 480),
            contentMode: .aspectFit,
            options: opts
        ) { image, info in
            DispatchQueue.main.async {
                if let img = image { self.loadedImage = img }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { self.imageLoading = false }
            }
        }
    }

    // MARK: - Navigation

    func navigate(_ delta: Int) {
        let next = vm.reviewIndex + delta
        guard next >= 0, next < vm.reviewQueue.count else { return }
        vm.reviewIndex = next
    }

    // MARK: - Actions

    func performDelete() {
        guard let item = currentItem else { return }
        errorText = nil
        // Instant — just queue for batch deletion later
        vm.queueForDeletion(item)
    }

    func performKeep() {
        guard let item = currentItem else { return }
        isProcessing = true
        errorText    = nil
        vm.keepItem(item) { error in
            isProcessing = false
            if let error {
                errorText = "Could not add to Keep album: \(error.localizedDescription)"
            } else {
                vm.reviewKept += 1
            }
            vm.removeCurrentFromQueue()
        }
    }

    func performMove() {
        guard let item = currentItem else { return }
        let name = albumNameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isProcessing = true
        errorText    = nil
        vm.moveItem(item, toAlbumNamed: name) { error in
            isProcessing = false
            if let error {
                errorText = "Could not move to album: \(error.localizedDescription)"
            } else {
                vm.reviewMoved  += 1
                albumNameInput   = ""
                showingAlbumInput = false
            }
            vm.removeCurrentFromQueue()
        }
    }
}
