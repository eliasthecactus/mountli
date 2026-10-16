import AppKit
import MountliCore
import SwiftUI

#if MOUNTLI_DIRECT
    import Sparkle
#endif

@main
struct MountliMacApp: App {
    @State private var model = MountliAppModel()
    #if MOUNTLI_DIRECT
        private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    private var screenshotFixtureEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-MOUNTLIScreenshotFixture")
    }

    var body: some Scene {
        WindowGroup("Mountli", id: "main") {
            AppRootView(model: model)
                .frame(minWidth: 850, minHeight: 560)
                .onOpenURL(perform: model.handleRecoveryURL)
        }
        .defaultSize(width: screenshotFixtureEnabled ? 1_440 : 1_040, height: screenshotFixtureEnabled ? 900 : 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Remote…") { model.showingAddRemote = true }.keyboardShortcut("n", modifiers: .command)
                Button("New Mount…") { model.showingAddMount = true }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.remotes.isEmpty)
            }
            CommandMenu("Mountli") {
                Button("Refresh All") { model.run { try await model.refreshAll() } }.keyboardShortcut("r", modifiers: .command)
                Button("Activity") { model.requestedSection = "Activity" }.keyboardShortcut("a", modifiers: [.command, .option])
                Button("Issues") { model.requestedSection = "Issues" }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            #if MOUNTLI_DIRECT
                CommandGroup(after: .appInfo) { Button("Check for Updates…") { updaterController.checkForUpdates(nil) } }
            #endif
        }

        MenuBarExtra(
            isInserted: Binding(
                get: { model.snapshot.document.settings.showMenuBarExtra },
                set: { enabled in model.run { try await model.setShowMenuBarExtra(enabled) } }
            )
        ) {
            MenuStatusView(model: model)
        } label: {
            Label {
                Text(model.mounts.isEmpty ? "Mountli" : "Mountli — \(model.overallStatus.label)")
            } icon: {
                if let menuBarSymbol {
                    Image(systemName: menuBarSymbol)
                } else {
                    Image(nsImage: Self.menuBarMark)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            NavigationStack { SettingsView(model: model) }
                .frame(width: 620, height: 620)
                .tint(.mountliEmerald)
        }
    }

    /// The mark is a 256-unit SVG with no intrinsic size; menu bar labels ignore SwiftUI frames,
    /// so it has to be sized as an NSImage or it renders at full size in the menu bar.
    private static let menuBarMark: NSImage = {
        let image = (NSImage(named: "MountliMark")?.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    private var menuBarSymbol: String? {
        if model.operationalStates.values.contains(where: { $0.activeTransfers > 0 }) { return "arrow.up.arrow.down.circle" }
        switch model.overallStatus {
        case .paused: return "pause.circle"
        case .offline: return "externaldrive.badge.xmark"
        case .error, .authenticationRequired, .degraded: return "exclamationmark.triangle"
        default: return nil
        }
    }
}

private struct MenuStatusView: View {
    @Environment(\.openWindow) private var openWindow
    let model: MountliAppModel
    private var active: [OperationRecord] { model.recentOperations.filter { $0.outcome == .running || $0.outcome == .pending } }
    private var issueCount: Int { model.unresolvedIssueCount }
    private var allPaused: Bool { !model.mounts.isEmpty && model.mounts.allSatisfy { model.operationalStates[$0.id]?.isPaused == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.mounts.isEmpty {
                    Label("Mountli", systemImage: "externaldrive").font(.headline)
                } else {
                    Label(model.overallStatus.label, systemImage: model.overallStatus.systemImage)
                        .font(.headline)
                        .foregroundStyle(model.overallStatus.tint)
                }
                Spacer()
                if issueCount > 0 {
                    Button {
                        model.requestedSection = "Issues"
                        openWindow(id: "main")
                        NSApplication.shared.activate()
                    } label: {
                        Label("\(issueCount)", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("Open Issues")
                }
            }
            Divider()
            if model.mounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No mounts yet").foregroundStyle(.secondary)
                    Button("Add a Mount…") {
                        openWindow(id: "main")
                        NSApplication.shared.activate()
                        if model.remotes.isEmpty { model.showingAddRemote = true } else { model.showingAddMount = true }
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.mounts) { mount in
                            let state = model.operationalStates[mount.id] ?? MountOperationalState(mountID: mount.id)
                            HStack {
                                Label(mount.displayName, systemImage: state.status.systemImage).lineLimit(1)
                                Spacer()
                                Text(state.status.label).font(.caption).foregroundStyle(.secondary)
                                Button {
                                    model.run { try await model.reveal(mount) }
                                } label: {
                                    Image(systemName: "folder")
                                }.help("Open in Finder")
                                Button {
                                    model.run { try await model.refresh(mount) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }.help("Refresh")
                            }
                        }
                    }
                }.frame(maxHeight: 190)
            }
            if !active.isEmpty {
                Divider()
                Text("Transfers").font(.headline)
                ForEach(active.prefix(4)) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(operation.kind.label)
                            Spacer()
                            Button(model.cancellationRequestedIDs.contains(operation.id) ? "Requested" : "Cancel", role: .destructive) {
                                Task { await model.cancelOperation(operation) }
                            }
                            .disabled(model.cancellationRequestedIDs.contains(operation.id))
                        }
                        if operation.totalBytes > 0 { ProgressView(value: Double(operation.completedBytes), total: Double(operation.totalBytes)) }
                    }
                }
            }
            Divider()
            HStack {
                Button(allPaused ? "Resume All" : "Pause All", systemImage: allPaused ? "play.fill" : "pause.fill") {
                    model.run { try await model.setAllPaused(!allPaused) }
                }.disabled(model.mounts.isEmpty)
                Button("Refresh All", systemImage: "arrow.clockwise") { model.run { try await model.refreshAll() } }.disabled(model.mounts.isEmpty)
            }
            HStack {
                Button("Open Mountli") {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 390)
        .task { await model.refreshActivity() }
    }
}
