import AVKit
import SwiftUI

struct StorageMapNavigation: View {
    @ObservedObject var model: AppModel
    var body: some View { NavigationStack(path: $model.path) { StorageMapView(model: model).navigationDestination(for: AppRoute.self) { route in
        switch route {
        case .review(let category): ReviewView(model: model, category: category)
        case .preview(let identifier): PreviewView(model: model, identifier: identifier)
        case .summary: SummaryView(model: model)
        case .result: ResultView(model: model)
        case .videos: VideoCatalogView(model: model)
        case .compression(let id): CompressionView(model: model, identifier: id)
        case .compare(let first, let second): ComparisonView(model: model, firstID: first, secondID: second)
        case .protectionRules: ProtectionRulesView(model: model)
        case .activity: ActivityView(model: model)
        default: EmptyView()
        }
    } } }
}

struct StorageMapView: View {
    @ObservedObject var model: AppModel
    var body: some View { ScrollView { LazyVStack(alignment: .leading, spacing: 16) {
        Text("Worth reviewing").font(.largeTitle.bold()); PrivacyPill()
        if model.visualUnavailableCount > 0 { Label("Visual comparison unavailable for \(model.visualUnavailableCount) items. No visual matches were guessed for them.", systemImage: "eye.slash") }
        if let message = model.optimizationMessage { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
        if model.protectionUnknown { Label("Protection rules cannot be fully checked. Manage rules in Settings before cleanup.", systemImage: "lock.shield") }
        if model.resumeReviewOffer != nil {
            Button("Resume review") { model.resumeReview() }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("storageMap.resumeReview")
            Button("Start over") { model.startOverReview() }.frame(minHeight: 44).accessibilityIdentifier("storageMap.startOverReview")
        }
        if model.access == .limited { Button { model.managePhotoAccess() } label: { Label("Limited Access · Manage Access", systemImage: "exclamationmark.triangle") }.frame(minHeight: 44) }
        if !model.recommendations.isEmpty && model.resumeReviewOffer == nil { Button { model.beginRecommendedReview() } label: { VStack(alignment: .leading, spacing: 8) { Label("Recommended first batch", systemImage: "sparkles").font(.headline); Text("\(model.recommendations.flatMap(\.candidateIDs).count) items · estimated \(ByteCountFormatter.string(fromByteCount: model.recommendations.reduce(0) { $0 + $1.estimatedBytes }, countStyle: .file))"); Text(model.recommendations.first?.reason ?? "Review at your pace").font(.caption); Text("Nothing is selected automatically.").font(.caption) }.frame(maxWidth: .infinity, alignment: .leading).padding().background(CKColor.keepSurface, in: RoundedRectangle(cornerRadius: 16)) }.buttonStyle(.plain).accessibilityIdentifier("storageMap.recommended") }
        Button { model.path.append(.videos) } label: { Label("Video compression · \(model.videos.count) videos", systemImage: "video.badge.waveform") }.frame(minHeight: 44).accessibilityIdentifier("storageMap.compression")
        if model.libraryItems.isEmpty {
            ContentUnavailableView("Nothing to review", systemImage: "photo.on.rectangle.angled", description: Text("No matching photos or videos were found in the library you allowed."))
        } else {
            Text("Estimated candidate size: \(ByteCountFormatter.string(fromByteCount: model.libraryItems.filter { !model.effectiveExcludedIDs.contains($0.id) }.reduce(0) { $0 + $1.estimatedBytes }, countStyle: .file)). Review before deciding what to remove.")
            if !model.userSkippedIDs.isEmpty { Text("\(model.userSkippedIDs.count) manually protected items excluded").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("storageMap.protectedCount") }
            ForEach(MediaCategory.allCases.filter { $0 != .recommended }, id: \.self) { category in
                let items = model.items(in: category)
                if !items.isEmpty { Button { model.beginReview(category: category); model.path.append(.review(category)) } label: { HStack {
                    Image(systemName: category == .largeVideos ? "video" : "photo.on.rectangle").frame(width: 44, height: 44)
                    VStack(alignment: .leading) { Text(category.rawValue).font(.headline); Text("\(items.count) items · estimated \(ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.estimatedBytes }, countStyle: .file))").font(.subheadline).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "chevron.right")
                }.padding().background(CKColor.surface, in: RoundedRectangle(cornerRadius: 16)) }.buttonStyle(.plain).accessibilityIdentifier("storageMap.category.\(category.rawValue)") }
            }
        }
    }.padding(16) }.background(CKColor.canvas).navigationTitle("Review")
    .alert("Review updated", isPresented: Binding(get: { model.reviewLifecycleMessage != nil }, set: { if !$0 { model.dismissReviewLifecycleMessage() } })) {
        Button("OK") { model.dismissReviewLifecycleMessage() }
    } message: { Text(model.reviewLifecycleMessage ?? "") }
    }
}

struct ReviewView: View {
    @ObservedObject var model: AppModel
    let category: MediaCategory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var columns: [GridItem] { dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible(minimum: 0))] : [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))] }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) {
        ReviewBatchHeader(model: model)
        Text("\(model.currentReviewBatch?.candidateIDs.count ?? 0) remaining in this batch · \(model.currentReviewBatch?.completedCount ?? 0) completed").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("review.batchCounts")
        if category == .similar { Text("Groups match close capture times, proportions and local visual features. Suggestions are not a quality guarantee. Compare before deciding; nothing is preselected.") }
        if model.libraryChanged { Label("Your library changed. Review again before deleting.", systemImage: "exclamationmark.triangle") }
        if category == .similar {
            let groups = similarityGroups
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                SimilarityGroupView(group: group, position: index + 1, total: groups.count, model: model, columns: columns)
            }
        } else { LazyVGrid(columns: columns, spacing: 12) { ForEach(currentItems) { LibraryAssetTile(item: $0, model: model) } } }
        if let message = model.reviewPersistenceMessage { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("review.persistenceError") }
        Button("Complete Batch") { model.completeCurrentBatch() }.frame(minHeight: 44).accessibilityIdentifier("review.completeBatch").layoutProbe("review.completeBatch")
    }.padding(16).padding(.bottom, 84) }.safeAreaInset(edge: .bottom) { VStack(spacing: 6) {
        Text("\(model.selectedIdentifiers.count) selected · estimated \(ByteCountFormatter.string(fromByteCount: model.selectedBytes, countStyle: .file))").font(.subheadline).monospacedDigit().accessibilityIdentifier("review.selectionCount")
        Button("Review Selection") { model.path.append(.summary) }.buttonStyle(PrimaryButtonStyle()).disabled(model.selectedIdentifiers.isEmpty || model.libraryChanged)
    }.padding().background(.bar).layoutProbe("review.footer") }.navigationTitle(category.rawValue) }
    private var currentItems: [LibraryItem] { let ids = Set(model.currentReviewBatch?.candidateIDs ?? []); return model.items(in: category).filter { ids.contains($0.id) } }
    private var similarityGroups: [SimilarityGroup] {
        Dictionary(grouping: currentItems) { $0.duplicateGroup ?? "single-\($0.id)" }
            .map { entry in SimilarityGroup(id: entry.key, items: entry.value.sorted {
                if $0.isSuggestedKeeper != $1.isSuggestedKeeper { return $0.isSuggestedKeeper }
                return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
            }) }
            .sorted { $0.id < $1.id }
    }
}

struct ReviewBatchHeader: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            Text("Batch \(model.currentReviewBatch?.number ?? 0) of \(model.currentReviewBatch?.totalBatches ?? 0)").font(.headline).accessibilityIdentifier("review.batchProgress")
            Spacer()
            Picker("Batch size", selection: Binding(get: { model.reviewSession?.batchSize ?? 20 }, set: { model.setBatchSize($0) })) {
                Text("20").tag(20); Text("50").tag(50); Text("100").tag(100)
            }.pickerStyle(.menu).accessibilityIdentifier("review.batchSize")
        }
    }
}

struct SimilarityGroup: Identifiable { let id: String; let items: [LibraryItem] }

struct SimilarityGroupView: View {
    let group: SimilarityGroup
    let position: Int
    let total: Int
    @ObservedObject var model: AppModel
    let columns: [GridItem]
    var body: some View { GroupBox { VStack(alignment: .leading, spacing: 12) {
        if let keeper = group.items.first(where: { $0.id == model.keeperID(for: group) }) ?? group.items.first {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.keeperID(for: group) == nil ? "Reference photo" : "Suggested keeper", systemImage: "shield.checkered").font(.headline).foregroundStyle(CKColor.keep)
                Text(model.keeperReason(for: group.id)).font(.caption).foregroundStyle(.secondary)
                LibraryAssetTile(item: keeper, model: model)
                if let other = group.items.first(where: { $0.id != keeper.id }) { Button("Compare photos") { model.path.append(.compare(keeper.id, other.id)) }.frame(minHeight: 44) }
            }.padding(10).background(CKColor.keepSurface, in: RoundedRectangle(cornerRadius: 12))
        }
        let candidates = group.items.filter { $0.id != (model.keeperID(for: group) ?? group.items.first?.id) }
        if !candidates.isEmpty { Text("Review candidates").font(.subheadline.bold()); LazyVGrid(columns: columns, spacing: 12) { ForEach(candidates) { candidate in VStack { LibraryAssetTile(item: candidate, model: model); if let keeper = group.items.first(where: { $0.id == model.keeperID(for: group) }) ?? group.items.first { Button("Compare with reference") { model.path.append(.compare(keeper.id, candidate.id)) }.frame(minHeight: 44) } } } } }
    } } label: { Text("Similar group \(position) of \(total) · \(group.items.count) items") }
    .accessibilityElement(children: .contain)
    }
}

struct LibraryAssetTile: View {
    let item: LibraryItem
    @ObservedObject var model: AppModel
    @State private var thumbnail: UIImage?
    var body: some View { VStack(alignment: .leading, spacing: 8) {
        Button { model.path.append(.preview(item.id)) } label: {
            RoundedRectangle(cornerRadius: 10).fill(CKColor.muted)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        if let thumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        } else { ProgressView().frame(width: proxy.size.width, height: proxy.size.height) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel("Preview \(accessibilityIdentity)").accessibilityIdentifier("review.preview.\(item.id)").accessibilityHint("Opens a full-size preview").layoutProbe("preview.\(item.id)")
        Text(ByteCountFormatter.string(fromByteCount: item.estimatedBytes, countStyle: .file)).font(.caption).layoutProbe("metadata.\(item.id)")
        if item.isSuggestedKeeper { Label("Suggested keeper", systemImage: "shield.checkered").font(.caption).foregroundStyle(CKColor.keep) }
        if item.isProtected && !model.unlockedIdentifiers.contains(item.id) { Button("Protected · Unlock") { model.unlockedIdentifiers.insert(item.id) }.frame(minHeight: 44).accessibilityLabel("Unlock \(accessibilityIdentity), protected") }
        else { Button { model.toggle(identifier: item.id) } label: { Label(model.selectedIdentifiers.contains(item.id) ? "Selected" : "Select", systemImage: model.selectedIdentifiers.contains(item.id) ? "checkmark.circle.fill" : "circle").frame(minHeight: 44) }.accessibilityIdentifier("review.select.\(item.id)").accessibilityLabel("\(model.selectedIdentifiers.contains(item.id) ? "Deselect" : "Select") \(accessibilityIdentity)").accessibilityHint("Marks this item for the Photos deletion confirmation") }
        Button("Skip & protect") { model.skipAndProtect(identifier: item.id) }.font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("review.skipProtect.\(item.id)").layoutProbe("skip.\(item.id)")
    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).layoutProbe("tile.\(item.id)").task(id: item.id) { thumbnail = await model.photoLibrary.thumbnail(identifier: item.id, targetSize: CGSize(width: 360, height: 360)) } }
    private var accessibilityIdentity: String {
        let date = item.createdAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown date"
        let size = ByteCountFormatter.string(fromByteCount: item.estimatedBytes, countStyle: .file)
        let states = [item.isSuggestedKeeper ? "suggested keeper" : nil, item.isProtected ? "protected" : nil, model.selectedIdentifiers.contains(item.id) ? "selected" : nil].compactMap { $0 }.joined(separator: ", ")
        return "\(item.title), \(date), estimated \(size)" + (states.isEmpty ? "" : ", \(states)")
    }
}

struct PreviewView: View {
    @ObservedObject var model: AppModel
    let identifier: String
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    private var item: LibraryItem? { model.item(identifier: identifier) }
    var body: some View { ScrollView { VStack(spacing: 20) {
        if let player { VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit).frame(minHeight: 180).layoutProbe("preview.player").onAppear { player.play() } }
        else if let image { Image(uiImage: image).resizable().scaledToFit() }
        else if item == nil { ContentUnavailableView("Media unavailable", systemImage: "exclamationmark.triangle") }
        else { ProgressView() }
        if let item { Text("\(item.pixelWidth) × \(item.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: item.estimatedBytes, countStyle: .file))")
            Button(model.selectedIdentifiers.contains(identifier) ? "Remove from deletion" : "Select for deletion") { model.toggle(identifier: identifier) }.buttonStyle(PrimaryButtonStyle()).disabled(item.isProtected && !model.unlockedIdentifiers.contains(identifier)) }
    }.padding(20) }.navigationTitle("Preview").task(id: identifier) {
        guard let item else { return }
        if item.isVideo, let playerItem = await model.photoLibrary.playerItem(identifier: identifier) { player = AVPlayer(playerItem: playerItem) }
        else { image = await model.photoLibrary.image(identifier: identifier) }
    } }
}

struct SummaryView: View {
    @ObservedObject var model: AppModel
    @State private var showPurchase = false
    @State private var deleting = false
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) {
        Text("Review before deleting").font(.title2.bold())
        Text("You selected \(model.selectedIdentifiers.count) items, about \(ByteCountFormatter.string(fromByteCount: model.selectedBytes, countStyle: .file)). Nothing else will be changed.")
        Label("Deleted items move to Recently Deleted in Photos, where Apple may keep them for up to 30 days unless you remove them sooner.", systemImage: "arrow.uturn.backward.circle")
        switch model.deletionGate {
        case .allowed: Button { Task { deleting = true; await model.deleteSelected(); deleting = false; model.path.append(.result) } } label: {
            if deleting { HStack { ProgressView().tint(.white); Text("Waiting for Photos…") } } else { Text("Ask Photos to Delete \(model.selectedIdentifiers.count) Items") }
        }.buttonStyle(PrimaryButtonStyle()).tint(.red).disabled(model.selectedIdentifiers.isEmpty || model.libraryChanged || deleting || model.isDeleting)
        case .purchaseRequired: Button("Unlock to delete these items") { showPurchase = true }.buttonStyle(PrimaryButtonStyle())
        case .unavailable: Label("This selection exceeds your free allowance, and purchases are unavailable.", systemImage: "exclamationmark.triangle")
        }
    }.padding(20) }.sheet(isPresented: $showPurchase) { PurchaseView(store: model.store) }.navigationTitle("Delete summary") }
}

struct PurchaseView: View {
    @ObservedObject var store: StoreService
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 20) {
        Text("Lifetime Unlock").font(.title2.bold())
        switch store.state {
        case .loading: ProgressView("Loading products…")
        case .cancelled: Label("Purchase canceled. Your selections are still here.", systemImage: "info.circle")
        case .failed(let message), .unavailable(let message): Label(message, systemImage: "exclamationmark.triangle")
        case .available: ForEach(store.products) { product in GroupBox { VStack(alignment: .leading, spacing: 8) { Text("Lifetime Unlock").font(.headline); Text(product.displayPrice).font(.title3.bold()); Text("One-time purchase. Unlimited cleanup and full video compression forever. No subscription or recurring charge."); Text("Free includes 100 confirmed deletions and 10 successful video compressions. Safety, protection, previews and recovery stay free.").font(.footnote); Button { Task { await store.purchase(product) } } label: { if store.operationInProgress { HStack { ProgressView().tint(.white); Text("Purchasing…") } } else { Text("Buy Lifetime Unlock · \(product.displayPrice)") } }.buttonStyle(PrimaryButtonStyle()).disabled(store.operationInProgress) } } }
        }
        Text("Payment is charged once to your Apple Account after confirmation.").font(.footnote)
        Button { Task { await store.restore() } } label: { if store.operationInProgress { HStack { ProgressView(); Text("Restoring…") } } else { Text("Restore Purchases") } }.frame(minHeight: 44).disabled(store.operationInProgress)
        if let url = LegalLinks.privacy { Link("Privacy Policy", destination: url) }
        if let url = LegalLinks.terms { Link("Terms of Use", destination: url) }
    }.padding(20) }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } } } }
}

struct ResultView: View {
    @ObservedObject var model: AppModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) {
        Image(systemName: model.result == .success ? "checkmark.circle.fill" : "exclamationmark.circle").font(.system(size: 52))
        Text(model.result == .success ? "Cleanup complete" : model.result == .cancelled ? "Deletion canceled" : model.result == .changedLibrary ? "Your library changed" : model.result == .noChanges ? "Nothing was deleted" : "Some items couldn’t be deleted").font(.title2.bold())
        Text("\(model.deleteOutcome.deleted.count) deleted · \(model.deleteOutcome.unchanged.count) unchanged · about \(ByteCountFormatter.string(fromByteCount: model.deleteOutcome.estimatedDeletedBytes, countStyle: .file))")
        GroupBox("Changed your mind?") { Text("Open the Photos app, then go to Albums › Recently Deleted to review or recover items Apple still retains.") }
        if model.result == .partial || model.result == .failed {
            Button("Review Unchanged Items") { model.reviewUnchangedItems() }.buttonStyle(PrimaryButtonStyle()).accessibilityHint("Returns to the deletion summary with unchanged items still selected")
        } else { Button(model.result == .changedLibrary ? "Review Again" : "Done") { model.finishResult() }.buttonStyle(PrimaryButtonStyle()) }
    }.padding(20) }.navigationBarBackButtonHidden() }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var restoreMessage: String?
    var body: some View { NavigationStack { List {
        Section("Photos") { Button("Manage Photo Access") { model.managePhotoAccess() }; Button("Rescan Library") { model.startScan() }.disabled(model.isScanning) }
        DeletionRecoverySection(model: model)
        Section("Protection rules") { NavigationLink("Albums and recent media") { ProtectionRulesView(model: model) }; Text("Safety, protection, previews and recovery are always free.").font(.footnote) }
        Section("Protected Items") {
            if model.protectedRecords.isEmpty { Text("No manually protected items") }
            ForEach(model.protectedRecords) { record in HStack { Text("Protected item"); Spacer(); Button("Remove protection") { model.removeUserProtection(identifier: record.id) }.accessibilityIdentifier("settings.removeProtection.\(record.id)") } }
        }
        Section("Purchases") {
            Button { Task { await model.store.restore(); restoreMessage = restoreResultMessage } } label: {
                if model.store.operationInProgress { HStack { ProgressView(); Text("Restoring…") } } else { Text("Restore Purchases") }
            }.disabled(model.store.operationInProgress)
            if let restoreMessage { Text(restoreMessage).font(.footnote).foregroundStyle(.secondary).accessibilityLabel("Restore result: \(restoreMessage)") }
        }
        Section("Legal") {
            if let url = LegalLinks.privacy { Link("Privacy Policy", destination: url) }
            if let url = LegalLinks.terms { Link("Terms of Use", destination: url) }
            if LegalLinks.privacy == nil || LegalLinks.terms == nil { Text("Legal links must be configured for release.").foregroundStyle(.secondary) }
        }
        Section("Help") {
            if let url = LegalLinks.support { Link("Support & Feedback", destination: url).accessibilityIdentifier("settings.support") }
            else { Text("Support contact is not configured in this build.").foregroundStyle(.secondary).accessibilityIdentifier("settings.supportUnavailable") }
        }
        Section { Text("Photo analysis happens on this iPhone. Stillmint does not upload your photos or videos.") }
    }.navigationTitle("Settings") } }
    private var restoreResultMessage: String {
        switch model.store.state {
        case .available: return "Purchases are up to date."
        case .cancelled: return "Restore was canceled."
        case .failed(let message), .unavailable(let message): return message
        case .loading: return "Checking purchases…"
        }
    }
}

enum LegalLinks {
    static var privacy: URL? { configured("CKPrivacyPolicyURL") }
    static var terms: URL? { configured("CKTermsOfUseURL") }
    static var support: URL? { configured("CKSupportURL") }
    private static func configured(_ key: String) -> URL? {
        validatedURL(Bundle.main.object(forInfoDictionaryKey: key) as? String)
    }
    static func validatedURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty, !value.contains("$("), !value.contains("<"),
              !value.lowercased().contains("placeholder"), !value.lowercased().contains("your-domain"),
              let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host.contains("."),
              !["example.com", "example.org", "example.net"].contains(host),
              !host.hasSuffix(".example"), !host.hasSuffix(".invalid"), !host.hasSuffix(".test"), !host.hasSuffix(".local"),
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
}
