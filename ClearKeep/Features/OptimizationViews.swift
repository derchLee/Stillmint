import AVKit
import SwiftUI

struct DeletionRecoverySection: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.deletionRecoveryPending {
            Section("Cleanup verification") {
                Text("A previous cleanup needs verification. No media will be deleted again. Verification is always free.").font(.footnote)
                Button {
                    model.retryPendingDeletionVerification()
                } label: {
                    HStack { if model.isVerifyingDeletion { ProgressView() }; Text(model.isVerifyingDeletion ? "Verifying…" : "Retry cleanup verification") }.frame(minHeight: 44)
                }.disabled(model.isVerifyingDeletion || model.isDeleting).accessibilityIdentifier("settings.retryDeletionVerification")
                if model.canCloseUnverifiedDeletion {
                    Text("The result cannot be proven. Closing records it as unverified, changes no allowance and deletes nothing. Confirmed cleanups still count normally.").font(.footnote)
                    Button("Close unverified cleanup") { model.closeUnverifiedDeletion() }
                        .frame(minHeight: 44).disabled(model.isVerifyingDeletion || model.isDeleting).accessibilityIdentifier("settings.closeUnverifiedDeletion")
                }
            }
        }
        #if DEBUG
        if let observation = DebugE2EFixture.deletionObservation(model) {
            Section("Fixture observations") { Text(observation).accessibilityIdentifier("e2e.deletionJournalCounters") }
        }
        #endif
    }
}

struct ComparisonView: View {
    @ObservedObject var model: AppModel
    let firstID: String
    let secondID: String
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) {
        Text("Compare before deciding").font(.title2.bold())
        Text("Choosing a keeper does not select any photo for deletion.").font(.subheadline)
        ForEach(0..<2, id: \.self) { index in
            let id = index == 0 ? firstID : secondID
            let label = index == 0 ? "Photo A" : "Photo B"
            Text(label).font(.headline)
            ComparisonPhoto(model: model, identifier: id)
            if let item = model.item(identifier: id) {
                Text("\(item.pixelWidth) × \(item.pixelHeight) · estimated \(ByteCountFormatter.string(fromByteCount: item.estimatedBytes, countStyle: .file))").font(.caption)
                Text(item.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Capture date unknown").font(.caption)
                if let group = item.duplicateGroup {
                    if model.reviewSession?.keeperOverrides?[group] == id || (model.reviewSession?.keeperOverrides?[group] == nil && item.isSuggestedKeeper) { Label("Current keeper", systemImage: "shield.checkered").foregroundStyle(CKColor.keep) }
                    Text(model.keeperReason(for: group)).font(.footnote)
                }
            }
            if let group = model.item(identifier: id)?.duplicateGroup {
                Button("Prefer \(label) as keeper") { model.chooseKeeper(id, groupID: group) }.frame(minHeight: 44).accessibilityLabel("Prefer \(label) as keeper without selecting deletion")
            }
            Button("Open \(label) full preview") { model.path.append(.preview(id)) }.frame(minHeight: 44).accessibilityLabel("Open \(label) full-size preview")
        }
    }.padding() }.navigationTitle("Compare") }
}

private struct ComparisonPhoto: View {
    let model: AppModel
    let identifier: String
    @State private var image: UIImage?
    var body: some View { Group { if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360) } else { ProgressView().frame(height: 180) } }.task(id: identifier) { image = await model.photoLibrary.image(identifier: identifier) } }
}

struct ProtectionRulesView: View {
    @ObservedObject var model: AppModel
    var body: some View { List {
        Section("Recent media") {
            Picker("Protect recent media", selection: Binding(get: { model.protectionRules.recentDays ?? 0 }, set: { days in var rules = model.protectionRules; rules.recentDays = days == 0 ? nil : days; model.updateProtectionRules(rules) })) {
                Text("Off").tag(0); Text("Last 7 days").tag(7); Text("Last 30 days").tag(30); Text("Last 90 days").tag(90)
            }
            Text("Media with an unknown capture date stays protected while this rule is on.").font(.footnote)
        }
        Section("Protected albums") {
            if !model.albumSnapshot.fullAccess { Label("Full Photo Access is needed to verify complete album membership.", systemImage: "lock.shield"); Button("Manage Photo Access") { model.managePhotoAccess() } }
            ForEach(model.albumSnapshot.titlesByAlbumID.keys.sorted(), id: \.self) { id in
                Toggle(model.albumSnapshot.titlesByAlbumID[id] ?? "Album", isOn: Binding(get: { model.protectionRules.protectedAlbumIDs.contains(id) }, set: { protect in var rules = model.protectionRules; if protect { rules.protectedAlbumIDs.insert(id) } else { rules.protectedAlbumIDs.remove(id) }; model.updateProtectionRules(rules) }))
            }
            ForEach(model.protectionRules.protectedAlbumIDs.filter { model.albumSnapshot.titlesByAlbumID[$0] == nil }.sorted(), id: \.self) { id in
                VStack(alignment: .leading) { Text("Protected album unavailable"); Button("Pause this album rule") { var rules = model.protectionRules; rules.protectedAlbumIDs.remove(id); model.updateProtectionRules(rules) } }
            }
            Text("If an active album rule cannot be verified, cleanup is paused. Changing rules starts a new review with no delete selections.").font(.footnote)
        }
    }.navigationTitle("Protection rules") }
}

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var filter = "All"
    @State private var statusFilter = "All"
    @State private var confirmClear = false
    private var entries: [ActivityReceipt] { model.activityEntries.filter { (filter == "All" || $0.kind.rawValue == filter) && (statusFilter == "All" || $0.status.rawValue == statusFilter) } }
    var body: some View { NavigationStack { List {
        Section { Picker("Operation type", selection: $filter) { Text("All").tag("All"); Text("Cleanup").tag("deletion"); Text("Compression").tag("compression") }.pickerStyle(.segmented) }
        Section { Picker("Status", selection: $statusFilter) { Text("All statuses").tag("All"); Text("Success").tag("success"); Text("Partial").tag("partial"); Text("Cancelled").tag("cancelled"); Text("Failed").tag("failed"); Text("Pending verification").tag("pendingVerification") } }
        if entries.isEmpty { ContentUnavailableView("No matching activity", systemImage: "clock", description: Text("Confirmed cleanup and compression results appear here. Your media stays in Photos.")) }
        ForEach(entries) { entry in NavigationLink { ActivityDetailView(entry: entry) } label: { VStack(alignment: .leading, spacing: 4) { Text(entry.kind == .deletion ? "Cleanup · \(entry.status.rawValue)" : "Compression · \(entry.status.rawValue)").font(.headline); Text(entry.date.formatted()).font(.caption); Text("\(entry.confirmedCount) confirmed · \(entry.unchangedCount) unchanged").font(.subheadline) } } }
        Section { Text("History is stored only on this iPhone. Clearing it does not reset allowances, protection or compression proofs.").font(.footnote); Button("Clear activity history", role: .destructive) { confirmClear = true } }
    }.navigationTitle("Activity").confirmationDialog("Clear local activity history?", isPresented: $confirmClear) { Button("Clear history", role: .destructive) { model.clearActivity() } } } }
}

struct ActivityDetailView: View {
    let entry: ActivityReceipt
    var body: some View { List {
        LabeledContent("Status", value: entry.status.rawValue)
        LabeledContent("Requested", value: "\(entry.requestedCount)")
        LabeledContent("Confirmed", value: "\(entry.confirmedCount)")
        LabeledContent("Unchanged", value: "\(entry.unchangedCount)")
        if let note = entry.verificationNote { Text(note).font(.body) }
        if let bytes = entry.estimatedDeletedSize { LabeledContent("Estimated removed media", value: size(bytes.bytes)); Text("Items may remain in Recently Deleted. This is not a measurement of device space freed.").font(.footnote) }
        if let source = entry.sourceSize { LabeledContent(source.provenance == .measured ? "Measured source size" : "Estimated source size", value: size(source.bytes)) }
        if let output = entry.outputSize { LabeledContent("Measured output size", value: size(output.bytes)) }
        if let comparison = entry.comparison { LabeledContent(entry.comparisonLabel, value: size(comparison.bytes)); Text("The original is kept by default. Keeping both can use more storage.").font(.footnote) }
        Text("Recovery: Open Photos › Recently Deleted to recover items Apple still retains.")
    }.navigationTitle("Operation details") }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct VideoCatalogView: View {
    @ObservedObject var model: AppModel
    var body: some View { List {
        Section { Text("Create smaller copies while keeping originals. 10 successful compressions are free; previews never use allowance.") }
        if model.videos.isEmpty { ContentUnavailableView("No authorized videos", systemImage: "video", description: Text("Scan your library or manage Photo Access.")) }
        ForEach(model.videos) { video in Button { model.path.append(.compression(video.id)) } label: { HStack { Image(systemName: "video").frame(width: 40); VStack(alignment: .leading) { Text(video.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Video"); Text("\(Int(video.duration)) sec · estimated \(ByteCountFormatter.string(fromByteCount: video.estimatedBytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right") } }.frame(minHeight: 44).accessibilityIdentifier("videos.open.\(video.id)") }
    }.navigationTitle("Video compression") }
}

struct CompressionView: View {
    @ObservedObject var model: AppModel
    let identifier: String
    @State private var profile: CompressionProfile = .balanced
    @State private var sample: CompressionSample?
    @State private var originalPlayer: AVPlayer?
    @State private var samplePlayer: AVPlayer?
    @State private var showPurchase = false
    @State private var action: Task<Void, Never>?
    @State private var localMessage: String?
    private var service: VideoCompressionService { model.compressionService }
    private var operations: [CompressionOperation] { model.compressionOperations.filter { $0.sourceID == identifier } }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        Text("Keep the moment. Make a smaller copy.").font(.title2.bold())
        Text("The original is always kept. Export quality depends on the source; compression is not lossless.")
        if let originalPlayer { Text("Original").font(.headline); VideoPlayer(player: originalPlayer).frame(height: 220) }
        Picker("Output quality", selection: $profile) { ForEach(CompressionProfile.allCases, id: \.self) { Text($0.title).tag($0) } }.disabled(service.isBusy)
        Text(profile.detail).font(.caption)
        Text(model.hasUnlimitedAccess ? "Lifetime · unlimited compression" : service.remainingFreeExports.map { "\($0) successful free compressions remaining" } ?? "Free allowance could not be verified")
        if service.isBusy {
            ProgressView(value: service.progress)
            Text(service.activeOperation?.state.rawValue ?? "Preparing preview")
            if service.activeOperation == nil || [.preflight, .exporting, .validating].contains(service.activeOperation!.state) {
                Button("Cancel current export") { action?.cancel(); service.cancel() }.frame(minHeight: 44)
            } else { Text("Finishing saved-copy verification. Your original is kept.").font(.footnote) }
        } else {
            Button("Create free short preview") { action = Task { do { if let sample { service.discardSample(sample) }; let created = try await service.preview(sourceID: identifier, profile: profile); sample = created; samplePlayer = AVPlayer(url: created.url); localMessage = nil } catch { localMessage = error.localizedDescription } } }.frame(minHeight: 44)
            Button("Compress and save new copy") {
                if !model.hasUnlimitedAccess && service.remainingFreeExports == 0 { showPurchase = true }
                else { action = Task { await model.compressVideo(identifier, profile: profile) } }
            }.buttonStyle(PrimaryButtonStyle())
        }
        if let sample, let samplePlayer { Text("Compressed sample · \(Int(sample.duration)) seconds · \(ByteCountFormatter.string(fromByteCount: sample.bytes, countStyle: .file)) measured").font(.headline); VideoPlayer(player: samplePlayer).frame(height: 220); Text("Sample size does not measure whole-video savings.").font(.caption) }
        if let message = localMessage ?? model.optimizationMessage { Label(message, systemImage: "info.circle") }
        ForEach(operations) { op in GroupBox { VStack(alignment: .leading, spacing: 10) {
            Text(op.state == .completed ? "Saved and verified · Keep both" : "Operation · \(op.state.rawValue)").font(.headline)
            if op.state == .pendingVerification || op.state == .saving || op.state == .verified { Button("Retry saved-copy verification") { Task { await model.retryCompression(op.id) } }.frame(minHeight: 44) }
            if let receipt = op.receipt { Text(receipt.potentialSavingsBytes == 0 ? "No space savings" : "Potential file size difference: \(ByteCountFormatter.string(fromByteCount: receipt.potentialSavingsBytes, countStyle: .file))\(receipt.sourceBytesAreMeasured ? " (measured)" : " (estimated)")"); Text("Your original is still kept. Device space has not necessarily increased.").font(.footnote); if receipt.potentialSavingsBytes > 0 { Button("Review original for deletion") { Task { await model.prepareOriginalCleanup(identifier) } }.frame(minHeight: 44) } }
        } } }
    }.padding() }.navigationTitle("Compress video").sheet(isPresented: $showPurchase) { PurchaseView(store: model.store) }
    .task(id: identifier) { if let item = await model.photoLibrary.playerItem(identifier: identifier) { originalPlayer = AVPlayer(playerItem: item) }; model.refreshCompressionOperations() }
    .onDisappear { originalPlayer?.pause(); samplePlayer?.pause(); if let sample { service.discardSample(sample) }; action?.cancel(); service.cancel() }
    }
}
