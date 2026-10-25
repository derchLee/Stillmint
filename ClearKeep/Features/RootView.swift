import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    var body: some View { model.finishedOnboarding ? AnyView(MainTabs(model: model)) : AnyView(WelcomeView(model: model)) }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView { VStack(alignment: .leading, spacing: 24) {
                PrivacyPill(); Text("Make space without guessing.").font(.largeTitle.bold())
                Text("Stillmint finds photos and videos worth reviewing. Nothing is selected or deleted without you.").font(.title3)
                GroupBox("Know the price before you scan") { VStack(alignment: .leading, spacing: 10) {
                    Text("Scan and preview for free. Delete 100 items and successfully compress 10 videos free, with no size or duration limits.")
                    switch model.store.state {
                    case .loading: ProgressView("Loading App Store prices…")
                    case .available: ForEach(model.store.products) { Text("Lifetime Unlock: \($0.displayPrice) · One-time purchase") }
                    case .unavailable(let message), .failed(let message): Label(message, systemImage: "exclamationmark.triangle")
                    case .cancelled: Text("Purchase canceled.")
                    }
                    Text("No subscription or recurring charge.").foregroundStyle(.secondary)
                    Text("Allowances are lifetime totals. Supported formats, available storage and protection rules still apply.").font(.footnote)
                }.frame(maxWidth: .infinity, alignment: .leading) }
                Button("Continue to Photo Access") { model.path.append(.permission) }.buttonStyle(PrimaryButtonStyle())
            }.padding(20) }.background(CKColor.canvas)
            .navigationDestination(for: AppRoute.self) { route in
                switch route { case .permission: PermissionView(model: model); case .scan: ScanView(model: model); default: EmptyView() }
            }
        }
    }
}

struct PermissionView: View {
    @ObservedObject var model: AppModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 52)).foregroundStyle(CKColor.keep)
        Text("Choose which photos Stillmint can review").font(.title2.bold())
        Text("Photo analysis stays on this iPhone. Limited Access works; Full Access lets you review more of your library.")
        if model.access == .denied { Label("Photo access is off.", systemImage: "exclamationmark.triangle"); Button("Open Settings") { model.managePhotoAccess() }.frame(minHeight: 44) }
        Button { Task { await model.requestPhotoAccess(); if model.access == .full || model.access == .limited { model.path.append(.scan) } } } label: {
            if model.isRequestingPhotoAccess { ProgressView().tint(.white).accessibilityLabel("Requesting photo access") } else { Text("Choose Photo Access") }
        }.buttonStyle(PrimaryButtonStyle()).disabled(model.isRequestingPhotoAccess)
        Button("Not Now") { model.path.removeAll() }.frame(maxWidth: .infinity, minHeight: 44).accessibilityHint("Returns to the welcome screen without requesting access")
    }.padding(20) }.navigationTitle("Photo access") }
}

struct ScanView: View {
    @ObservedObject var model: AppModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) {
        PrivacyPill(); Text(model.scanState == .paused ? "Scan paused" : "Reviewing your library on this iPhone…").font(.title2.bold())
        ProgressView(value: Double(model.scanAnalyzed), total: Double(max(model.scanTotal, 1)))
        Text("\(model.scanAnalyzed) of \(model.scanTotal) items reviewed").monospacedDigit()
        if model.scanState == .failed { Label("The scan stopped. Retry when you’re ready.", systemImage: "exclamationmark.triangle") }
        if model.unavailableAssetCount > 0 { Label("\(model.unavailableAssetCount) iCloud items were unavailable and were skipped. Download them in Photos, then rescan.", systemImage: "icloud.slash") }
        if model.visualUnavailableCount > 0 { Label("Visual comparison was unavailable for \(model.visualUnavailableCount) items. Other categories and previews still work.", systemImage: "eye.slash") }
        if model.scanState == .running { Button("Pause Scan") { model.pauseScan() }.buttonStyle(PrimaryButtonStyle()) }
        else if model.scanState == .complete { Button("Review Results") { model.path.removeAll(); model.finishedOnboarding = true }.buttonStyle(PrimaryButtonStyle()) }
        else { Button(model.scanState == .paused ? "Resume Scan" : "Start On-device Scan") { model.startScan() }.buttonStyle(PrimaryButtonStyle()) }
    }.padding(20) }.navigationTitle("On-device scan") }
}

struct MainTabs: View {
    @ObservedObject var model: AppModel
    var body: some View { TabView {
        StorageMapNavigation(model: model).tabItem { Label("Review", systemImage: "photo.on.rectangle.angled") }
        ActivityView(model: model).tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
        SettingsView(model: model).tabItem { Label("Settings", systemImage: "gearshape") }
    } }
}
