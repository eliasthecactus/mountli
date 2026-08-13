import MountliCore
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

private enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case mounts = "Mounts"
    case remotes = "Remotes"
    case activity = "Activity"
    case issues = "Issues"
    case settings = "Settings"

    var id: Self { self }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .mounts: "externaldrive"
        case .remotes: "network"
        case .activity: "arrow.up.arrow.down"
        case .issues: "exclamationmark.triangle"
        case .settings: "gearshape"
        }
    }
}

struct AppRootView: View {
    @Bindable var model: MountliAppModel
    @AppStorage("onboarding.completed.v1") private var onboardingCompleted = false

    var body: some View {
        Group {
            if onboardingCompleted {
                ContentView(model: model)
            } else {
                OnboardingView(model: model) { onboardingCompleted = true }
            }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-MOUNTLIScreenshotFixture") {
                model.installInterfaceTestFixture()
            } else {
                await model.bootstrap()
                await model.monitorActivity()
            }
        }
    }
}

private struct OnboardingView: View {
    let model: MountliAppModel
    let finish: () -> Void
    @State private var step = 0

    private let titles = ["Welcome to MOUNTLI", "Add your storage", "Stay informed", "Add to Finder & Files"]

    private var isCompactPhone: Bool {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .phone
        #else
            false
        #endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: isCompactPhone ? 16 : 24) {
                Spacer(minLength: isCompactPhone ? 8 : 24)
                MountliMark(size: isCompactPhone ? 60 : 72)
                Text(titles[step])
                    .font((isCompactPhone ? Font.title : Font.largeTitle).bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    switch step {
                    case 0:
                        VStack(spacing: 12) {
                            Text("Rclone in Finder & Files").font(.title3)
                            Label("No MOUNTLI account, hosted relay, ads, or telemetry", systemImage: "hand.raised.fill")
                            Text(
                                "Credentials and configuration stay encrypted on this device. Files travel directly between your device and the storage services you choose."
                            )
                        }
                    case 1:
                        VStack(spacing: 14) {
                            Text(
                                "Create a remote with rclone’s native setup questions, or import an existing rclone.conf. Every device is configured independently."
                            )
                            Button("Add a Remote", systemImage: "plus.circle") {
                                model.showingAddRemote = true
                                step = 2
                            }.buttonStyle(.borderedProminent)
                                .disabled(model.isLoading || model.catalog.isEmpty)
                            Button("Import rclone.conf", systemImage: "square.and.arrow.down") {
                                model.showingConfigImport = true
                                step = 2
                            }
                            .disabled(model.isLoading || !model.managedPolicy.allowConfigImport)
                        }
                    case 2:
                        VStack(spacing: 14) {
                            Text("Notifications are optional and requested only if you enable alerts for action-required events or completed transfers.")
                            Button("Enable Action Required Alerts") {
                                Task {
                                    let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
                                    guard allowed else { return }
                                    var settings = model.snapshot.document.settings.notifications
                                    settings.actionRequired = true
                                    try? await model.setNotificationSettings(settings)
                                }
                            }
                        }
                    default:
                        VStack(spacing: 12) {
                            #if os(macOS)
                                Label("After adding a mount, MOUNTLI opens its Finder location.", systemImage: "finder")
                            #else
                                Label("After adding a mount, enable and open its location in Files.", systemImage: "folder")
                            #endif
                            Text("Apple manages local downloads, materialization, and disk space. MOUNTLI does not create a second file browser.")
                            Group {
                                #if os(macOS)
                                    Button("Add to Finder", systemImage: "externaldrive.badge.plus") {
                                        model.showingAddMount = true
                                    }
                                #else
                                    Button("Add to Files", systemImage: "externaldrive.badge.plus") {
                                        model.showingAddMount = true
                                    }
                                #endif
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.remotes.isEmpty)
                        }
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: isCompactPhone ? 360 : 560)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: isCompactPhone ? 8 : 24)
                HStack {
                    if step > 0 { Button("Back") { step -= 1 } }
                    Spacer()
                    if step == 3 {
                        Button("Get Started", action: finish).buttonStyle(.borderedProminent)
                    } else {
                        Button("Continue") { step += 1 }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(isCompactPhone ? 20 : 32)
            .navigationTitle("Step \(step + 1) of 4")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .sheet(isPresented: Binding(get: { model.showingAddRemote }, set: { model.showingAddRemote = $0 })) {
            RemoteWizard(model: model)
        }
        .sheet(isPresented: Binding(get: { model.showingConfigImport }, set: { model.showingConfigImport = $0 })) {
            ConfigImportFlow(model: model)
        }
        .sheet(isPresented: Binding(get: { model.showingAddMount }, set: { model.showingAddMount = $0 })) {
            MountWizard(model: model)
        }
    }
}

struct ContentView: View {
    @Bindable var model: MountliAppModel
    @State private var selection: SidebarSection? = .overview
    @State private var compactSelection: SidebarSection = .overview
    @State private var compactPath: [SidebarSection] = []
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var allPaused: Bool {
        !model.mounts.isEmpty
            && model.mounts.allSatisfy { model.operationalStates[$0.id]?.isPaused == true }
    }

    var body: some View {
        Group {
            #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone && horizontalSizeClass == .compact {
                    compactNavigation
                } else {
                    splitNavigation
                }
            #else
                splitNavigation
            #endif
        }
        .sheet(isPresented: $model.showingAddRemote, onDismiss: { model.selectedRemoteID = nil }) {
            RemoteWizard(model: model, editing: model.remotes.first { $0.id == model.selectedRemoteID })
        }
        .sheet(isPresented: $model.showingAddMount) { MountWizard(model: model) }
        .sheet(isPresented: $model.showingConfigImport) { ConfigImportFlow(model: model) }
        .sheet(
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            ActionFailureView(
                title: "MOUNTLI couldn’t complete that action",
                message: model.presentedError ?? "Unknown error",
                dismiss: { model.presentedError = nil }
            )
        }
        #if os(macOS)
            .alert(
                "Dirty data was preserved",
                isPresented: Binding(
                    get: { model.preservedDataURL != nil },
                    set: { if !$0 { model.preservedDataURL = nil } }
                )
            ) {
                Button("Show in Finder") {
                    if let url = model.preservedDataURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    model.preservedDataURL = nil
                }
                Button("Done", role: .cancel) { model.preservedDataURL = nil }
            } message: {
                Text("Apple preserved local data from the removed location. Review it before deleting anything.")
            }
        #endif
        .tint(.mountliEmerald)
        .onChange(of: model.requestedSection) { _, requested in
            guard let requested, let section = SidebarSection(rawValue: requested) else { return }
            selection = section
            #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone && horizontalSizeClass == .compact,
                    section == .remotes || section == .issues
                {
                    compactSelection = .overview
                    compactPath = [section]
                } else {
                    compactSelection = section
                    compactPath.removeAll()
                }
            #else
                compactSelection = section
            #endif
            model.requestedSection = nil
        }
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarSection.allCases.filter { $0 != .settings }) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
                Section {
                    Label(SidebarSection.settings.rawValue, systemImage: SidebarSection.settings.icon)
                        .tag(SidebarSection.settings)
                }
            }
            .navigationTitle("MOUNTLI")
            .safeAreaInset(edge: .top) { brandHeader }
        } detail: {
            selectedView(selection ?? .overview)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        #if os(macOS)
                            Menu("Add", systemImage: "plus") {
                                Button("Remote…") { model.showingAddRemote = true }
                                Button("Mount…") { model.showingAddMount = true }.disabled(model.remotes.isEmpty)
                            }
                            Button("Refresh All", systemImage: "arrow.clockwise") { model.run { try await model.refreshAll() } }
                            Button(allPaused ? "Resume All" : "Pause All", systemImage: allPaused ? "play.fill" : "pause.fill") {
                                model.run { try await model.setAllPaused(!allPaused) }
                            }
                        #endif
                        StatusPill(status: model.overallStatus)
                    }
                }
        }
    }

    #if os(iOS)
        private var compactNavigation: some View {
            TabView(selection: $compactSelection) {
                NavigationStack(path: $compactPath) {
                    OverviewView(model: model)
                        .navigationDestination(for: SidebarSection.self) { selectedView($0) }
                }
                .tabItem { Label("Overview", systemImage: SidebarSection.overview.icon) }
                .tag(SidebarSection.overview)
                NavigationStack { MountsView(model: model) }
                    .tabItem { Label("Mounts", systemImage: SidebarSection.mounts.icon) }
                    .tag(SidebarSection.mounts)
                NavigationStack { ActivityView(model: model) }
                    .tabItem { Label("Activity", systemImage: SidebarSection.activity.icon) }
                    .tag(SidebarSection.activity)
                NavigationStack { SettingsView(model: model) }
                    .tabItem { Label("Settings", systemImage: SidebarSection.settings.icon) }
                    .tag(SidebarSection.settings)
            }
        }
    #endif

    @ViewBuilder private func selectedView(_ section: SidebarSection) -> some View {
        switch section {
        case .overview: OverviewView(model: model)
        case .mounts: MountsView(model: model)
        case .remotes: RemotesView(model: model)
        case .activity: ActivityView(model: model)
        case .issues: IssuesView(model: model)
        case .settings: SettingsView(model: model)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            MountliMark(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("MOUNTLI").font(.headline)
                Text("Rclone in Finder & Files").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal).padding(.top, 8)
    }
}

struct OverviewView: View {
    @Bindable var model: MountliAppModel
    var body: some View {
        List {
            Section("Status") {
                LabeledContent("All mounts") { StatusPill(status: model.overallStatus) }
                LabeledContent("Active transfers", value: "\(model.operationalStates.values.reduce(0) { $0 + $1.activeTransfers })")
                LabeledContent("Requires action", value: "\(model.unresolvedIssueCount)")
            }
            Section("Quick actions") {
                Button("Add Remote", systemImage: "network.badge.shield.half.filled") { model.showingAddRemote = true }
                Button("Add Mount", systemImage: "externaldrive.badge.plus") { model.showingAddMount = true }
                    .disabled(model.remotes.isEmpty)
                Button("Import rclone.conf", systemImage: "square.and.arrow.down") { model.showingConfigImport = true }
                    .disabled(!model.managedPolicy.allowConfigImport)
            }
            Section("Manage") {
                NavigationLink("Remotes", destination: RemotesView(model: model))
                NavigationLink("Issues", destination: IssuesView(model: model))
            }
        }
        .navigationTitle("Overview")
    }
}

struct MountsView: View {
    @Bindable var model: MountliAppModel
    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading mounts…")
            } else if model.mounts.isEmpty {
                ContentUnavailableView {
                    Label("No mounts yet", systemImage: "externaldrive.badge.plus")
                } description: {
                    Text("Create a File Provider location backed by one of your rclone remotes.")
                } actions: {
                    Button("Add Mount") { model.showingAddMount = true }.buttonStyle(.borderedProminent).disabled(model.remotes.isEmpty)
                    if model.remotes.isEmpty { Button("Add a Remote First") { model.showingAddRemote = true } }
                }
            } else {
                List {
                    Section {
                        ForEach(model.mounts) { mount in
                            NavigationLink {
                                MountDetailView(model: model, mountID: mount.id)
                            } label: {
                                MountRow(model: model, mount: mount)
                            }
                        }
                    } header: {
                        Text("Finder & Files Locations")
                    } footer: {
                        Text("Apple manages downloaded files and disk space. MOUNTLI connects each location directly to its storage provider.")
                    }
                }
            }
        }
        .navigationTitle("Mounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Add Mount", systemImage: "plus") { model.showingAddMount = true }.disabled(model.remotes.isEmpty) }
        }
    }
}

private struct MountRow: View {
    let model: MountliAppModel
    let mount: MountDefinition
    private var remote: RemoteProfile? { model.remotes.first { $0.id == mount.remoteID } }
    private var state: MountOperationalState { model.operationalStates[mount.id] ?? MountOperationalState(mountID: mount.id) }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.status.systemImage).font(.title2)
                .foregroundStyle(state.status == .error ? .red : Color.mountliEmerald).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(mount.displayName).font(.headline)
                    if mount.readOnly || model.managedPolicy.forceReadOnly { Text("READ ONLY").font(.caption2.bold()).foregroundStyle(.secondary) }
                }
                Text("\(remote?.displayName ?? "Missing remote")\(mount.root.isEmpty ? "" : " / \(mount.root)")")
                    .foregroundStyle(.secondary).lineLimit(1)
                if state.pendingOperations > 0 { Text("\(state.pendingOperations) pending operations").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            StatusPill(status: state.status)
        }.padding(.vertical, 6)
    }
}

private struct MountDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let model: MountliAppModel
    let mountID: UUID
    @State private var rename = ""
    @State private var showingRename = false
    @State private var showingRemoval = false
    @State private var capabilities: BackendCapabilities?
    @State private var quota: QuotaUsage?

    private var mount: MountDefinition? { model.mounts.first { $0.id == mountID } }
    private var remote: RemoteProfile? { mount.flatMap { value in model.remotes.first { $0.id == value.remoteID } } }
    private var state: MountOperationalState? { model.operationalStates[mountID] }

    var body: some View {
        Form {
            if let mount {
                Section("Status") {
                    LabeledContent("State") { StatusPill(status: state?.status ?? .connecting) }
                    if let date = state?.lastSuccessfulEnumeration { LabeledContent("Last refresh") { Text(date, style: .relative) } }
                    LabeledContent("Pending operations", value: "\(state?.pendingOperations ?? 0)")
                }
                Section("Location") {
                    LabeledContent("Remote", value: remote?.displayName ?? "Missing")
                    LabeledContent("Root", value: mount.root.isEmpty ? "/" : mount.root)
                    LabeledContent("Access", value: mount.readOnly || model.managedPolicy.forceReadOnly ? "Read only" : "Read and write")
                    Picker(
                        "Network",
                        selection: Binding(
                            get: { mount.networkPolicy },
                            set: { policy in model.run { try await model.setMountNetworkPolicy(policy, mount: mount) } }
                        )
                    ) { ForEach(NetworkPolicy.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .disabled(!model.managedPolicy.allowCellular)
                    if !model.managedPolicy.allowCellular { Text("Managed by your organization").font(.caption).foregroundStyle(.secondary) }
                }
                if let capabilities {
                    Section("Capabilities") {
                        LabeledContent("Backend access", value: capabilities.readOnly ? "Read only" : "Read and write")
                        LabeledContent("Server-side move", value: capabilities.serverSideMove ? "Available" : "Unavailable")
                        if let quota {
                            LabeledContent("Used", value: quota.used.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable")
                            LabeledContent("Free", value: quota.free.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable")
                        }
                    }
                }
                Section("Actions") {
                    Button(Self.openLabel, systemImage: "folder") { model.run { try await model.reveal(mount) } }
                    Button("Refresh", systemImage: "arrow.clockwise") { model.run { try await model.refresh(mount) } }
                    Button(state?.isPaused == true ? "Resume Sync" : "Pause Sync", systemImage: state?.isPaused == true ? "play.fill" : "pause.fill") {
                        model.run { try await model.setPaused(state?.isPaused != true, mount: mount) }
                    }
                    if let remote { Button("Reconnect", systemImage: "bolt.horizontal.circle") { model.run { try await model.reconnect(remote) } } }
                    Button("Rename", systemImage: "pencil") {
                        rename = mount.displayName
                        showingRename = true
                    }
                    Button("Remove Mount", systemImage: "trash", role: .destructive) { showingRemoval = true }
                }
            } else {
                ContentUnavailableView("Mount removed", systemImage: "externaldrive.badge.xmark")
            }
        }
        .navigationTitle(mount?.displayName ?? "Mount")
        .alert("Rename Mount", isPresented: $showingRename) {
            TextField("Name", text: $rename)
            Button("Rename") { if let mount { model.run { try await model.renameMount(mount, to: rename) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this mount?", isPresented: $showingRemoval, titleVisibility: .visible) {
            if let mount {
                #if os(macOS)
                    Button("Remove and preserve dirty user data") { remove(mount, preserve: true) }
                    Button("Remove and discard cached copies", role: .destructive) { remove(mount, preserve: false) }
                #else
                    Button("Remove from Files", role: .destructive) { remove(mount, preserve: false) }
                #endif
            }
        } message: {
            #if os(macOS)
                Text("Removal is blocked while uploads are pending. Preserved dirty data is revealed in Finder.")
            #else
                Text("Removal is blocked while uploads are pending. Removing the location deletes local materializations from Files, not the remote data.")
            #endif
        }
        .task(id: mountID) {
            guard let mount else { return }
            do {
                let result = try await model.probeMount(remoteID: mount.remoteID, root: mount.root)
                capabilities = result
                if result.reportsQuota { quota = try? await model.quota(remoteID: mount.remoteID, root: mount.root) }
            } catch {
                capabilities = nil
            }
        }
    }

    private func remove(_ mount: MountDefinition, preserve: Bool) {
        Task {
            do {
                _ = try await model.removeMount(mount, preserveDirtyData: preserve)
                dismiss()
            } catch { model.presentedError = error.localizedDescription }
        }
    }

    private static var openLabel: String {
        #if os(macOS)
            "Open in Finder"
        #else
            "Open in Files"
        #endif
    }
}

struct RemotesView: View {
    @Bindable var model: MountliAppModel
    var body: some View {
        Group {
            if model.remotes.isEmpty {
                ContentUnavailableView {
                    Label("No remotes yet", systemImage: "network.badge.shield.half.filled")
                } description: {
                    Text("Credentials stay in an encrypted local vault and are never sent to MOUNTLI servers.")
                } actions: {
                    Button("Add Remote") { model.showingAddRemote = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List(model.remotes) { remote in
                    NavigationLink {
                        RemoteDetailView(model: model, remoteID: remote.id)
                    } label: {
                        HStack(spacing: 14) {
                            ProviderGlyph(type: remote.backendType)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(remote.displayName).font(.headline)
                                Text("\(remote.backendType) · \(remote.engineName)").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(model.mounts.filter { $0.remoteID == remote.id }.count) mounts").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle("Remotes")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add Remote", systemImage: "plus") { model.showingAddRemote = true } } }
    }
}

private struct RemoteDetailView: View {
    let model: MountliAppModel
    let remoteID: UUID
    @State private var showingExport = false
    @State private var connectionMessage: String?
    private var remote: RemoteProfile? { model.remotes.first { $0.id == remoteID } }
    private var dependentMounts: [MountDefinition] { model.mounts.filter { $0.remoteID == remoteID } }
    private var dependentOverlays: [RemoteProfile] {
        guard let remote, let graph = try? RemoteDependencyGraph(remotes: model.remotes) else { return [] }
        return model.remotes.filter { graph.dependencies[$0.engineName]?.contains(remote.engineName) == true }
    }
    var body: some View {
        Form {
            if let remote {
                Section("Remote") {
                    LabeledContent("Backend", value: remote.backendType)
                    LabeledContent("rclone section", value: remote.engineName)
                }
                Section("Dependencies") {
                    if dependentMounts.isEmpty && dependentOverlays.isEmpty { Text("Not used by a mount or overlay").foregroundStyle(.secondary) }
                    ForEach(dependentMounts) { Label($0.displayName, systemImage: "externaldrive") }
                    ForEach(dependentOverlays) { Label($0.displayName, systemImage: "point.3.connected.trianglepath.dotted") }
                }
                Section("Actions") {
                    Button("Test Connection", systemImage: "checkmark.circle") { check(remote, reconnect: false) }
                    Button("Reconnect", systemImage: "bolt.horizontal.circle") { check(remote, reconnect: true) }
                    Button("Edit", systemImage: "pencil") {
                        model.selectedRemoteID = remote.id
                        model.showingAddRemote = true
                    }
                    Button("Export Selected…", systemImage: "square.and.arrow.up") { showingExport = true }
                        .disabled(!model.managedPolicy.allowConfigExport)
                    Button("Delete", systemImage: "trash", role: .destructive) { model.run { try await model.deleteRemote(remote) } }
                        .disabled(!dependentMounts.isEmpty || !dependentOverlays.isEmpty)
                }
            }
        }
        .navigationTitle(remote?.displayName ?? "Remote")
        .sheet(isPresented: $showingExport) { if let remote { ConfigExportFlow(model: model, selectedRemote: remote) } }
        .alert(
            "Connection",
            isPresented: Binding(
                get: { connectionMessage != nil },
                set: { if !$0 { connectionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { connectionMessage = nil }
        } message: {
            Text(connectionMessage ?? "")
        }
    }

    private func check(_ remote: RemoteProfile, reconnect: Bool) {
        Task {
            do {
                if reconnect { try await model.reconnect(remote) } else { try await model.testConnection(remote) }
                connectionMessage = reconnect ? "MOUNTLI reconnected this remote and refreshed its mounts." : "Connection successful."
            } catch {
                model.presentedError = error.localizedDescription
            }
        }
    }
}

private struct ProviderGlyph: View {
    let type: String
    var body: some View {
        Image(systemName: type == "crypt" ? "lock.fill" : "cloud.fill").font(.title3).foregroundStyle(Color.mountliEmerald)
            .frame(width: 38, height: 38).background(Color.mountliEmerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ActivityView: View {
    let model: MountliAppModel
    @State private var confirmingClear = false

    private var active: [OperationRecord] {
        model.recentOperations.filter { $0.outcome == .running || $0.outcome == .pending }
    }
    private var completedHistory: [OperationRecord] {
        model.recentOperations.filter {
            $0.outcome == .succeeded || $0.outcome == .failed || $0.outcome == .cancelled
        }
    }

    private var pendingCount: Int {
        model.operationalStates.values.reduce(0) { $0 + $1.pendingOperations }
    }
    var body: some View {
        Group {
            if model.recentOperations.isEmpty && pendingCount == 0 {
                ContentUnavailableView(
                    "No recent activity",
                    systemImage: "clock",
                    description: Text("Transfers and sync decisions will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("activity-empty-state")
            } else {
                List {
                    Section("Current") {
                        if active.isEmpty { Text("No active transfers").foregroundStyle(.secondary) }
                        ForEach(active) { operation in
                            ActiveOperationRow(model: model, operation: operation)
                        }
                        LabeledContent("Pending operations", value: "\(pendingCount)")
                    }
                    Section("Recent") {
                        if model.recentOperations.filter({ $0.outcome != .running && $0.outcome != .pending }).isEmpty {
                            Text("No completed activity").foregroundStyle(.secondary)
                        } else {
                            ForEach(model.recentOperations.filter { $0.outcome != .running && $0.outcome != .pending }) { operation in
                                HStack {
                                    Button {
                                        model.requestedOperationID = operation.id
                                    } label: {
                                        HStack {
                                            Image(systemName: operation.kind.systemImage)
                                                .foregroundStyle(operation.outcome == .failed ? .red : Color.mountliEmerald)
                                                .frame(width: 28)
                                            VStack(alignment: .leading) {
                                                Text(operation.kind.label)
                                                Text(operation.startedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    Spacer()
                                    if operation.outcome == .retryableFailure,
                                        let mount = model.mounts.first(where: { $0.id == operation.mountID })
                                    {
                                        Button("Retry") { model.run { try await model.refresh(mount) } }
                                        if let issue = issue(for: operation) {
                                            Button("View Issue") {
                                                model.requestedIssueID = issue.id
                                                model.requestedSection = "Issues"
                                            }
                                        }
                                    } else {
                                        Text(operation.outcome.label).font(.caption.bold()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear History", systemImage: "trash") { confirmingClear = true }
                    .disabled(completedHistory.isEmpty)
            }
        }
        .confirmationDialog("Clear completed activity history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                model.run { try await model.clearActivityHistory() }
            }
        } message: {
            Text("Pending work, retryable transfers, and unresolved Issues are preserved.")
        }
        .sheet(item: operationBinding) { operation in
            OperationDetailView(model: model, operation: operation)
        }
        .task { await model.refreshActivity() }
        .refreshable { await model.refreshActivity() }
    }

    private var operationBinding: Binding<OperationRecord?> {
        Binding(
            get: {
                model.requestedOperationID.flatMap { id in
                    model.recentOperations.first { $0.id == id }
                }
            },
            set: { if $0 == nil { model.requestedOperationID = nil } }
        )
    }

    private func issue(for operation: OperationRecord) -> IssueRecord? {
        model.durableIssues.first {
            $0.mountID == operation.mountID
                && (operation.diagnosticCode == nil || $0.diagnosticCode == operation.diagnosticCode)
        }
    }
}
private struct OperationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let model: MountliAppModel
    let operation: OperationRecord

    private var mount: MountDefinition? {
        model.mounts.first { $0.id == operation.mountID }
    }
    private var issue: IssueRecord? {
        model.durableIssues.first {
            $0.mountID == operation.mountID
                && (operation.diagnosticCode == nil || $0.diagnosticCode == operation.diagnosticCode)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Operation") {
                    LabeledContent("Type", value: operation.kind.label)
                    LabeledContent("Status", value: operation.outcome.label)
                    if let mount { LabeledContent("Mount", value: mount.displayName) }
                    LabeledContent("Started") { Text(operation.startedAt, format: .dateTime) }
                    if let completedAt = operation.completedAt {
                        LabeledContent("Completed") { Text(completedAt, format: .dateTime) }
                    }
                    if operation.totalBytes > 0 {
                        LabeledContent(
                            "Transferred",
                            value:
                                "\(ByteCountFormatter.string(fromByteCount: operation.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: operation.totalBytes, countStyle: .file))"
                        )
                    }
                }
                Section("Support") {
                    LabeledContent("Operation ID", value: operation.id.uuidString.lowercased())
                    if let code = operation.diagnosticCode {
                        LabeledContent("Diagnostic code", value: code)
                    }
                    if let issue {
                        Button("Open Related Issue") {
                            dismiss()
                            model.requestedIssueID = issue.id
                            model.requestedSection = "Issues"
                        }
                    }
                }
            }
            .navigationTitle("Activity Detail")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 500, minHeight: 420)
        #endif
    }
}

private struct ActiveOperationRow: View {
    let model: MountliAppModel
    let operation: OperationRecord
    private var speed: Double {
        Date().timeIntervalSince(operation.startedAt) > 0 ? Double(operation.completedBytes) / Date().timeIntervalSince(operation.startedAt) : 0
    }
    private var eta: TimeInterval? {
        speed > 0 && operation.totalBytes > operation.completedBytes ? Double(operation.totalBytes - operation.completedBytes) / speed : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(operation.kind.label, systemImage: operation.kind.systemImage)
                Spacer()
                Button(model.cancellationRequestedIDs.contains(operation.id) ? "Cancellation Requested" : "Cancel", role: .destructive) {
                    Task { await model.cancelOperation(operation) }
                }
                .disabled(model.cancellationRequestedIDs.contains(operation.id))
            }
            if operation.totalBytes > 0 { ProgressView(value: Double(operation.completedBytes), total: Double(operation.totalBytes)) }
            HStack {
                Text(
                    "\(ByteCountFormatter.string(fromByteCount: operation.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: operation.totalBytes, countStyle: .file))"
                )
                Spacer()
                if speed > 0 { Text("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s") }
                if let eta {
                    Text("· \(Int(eta) / 60)m \(Int(eta) % 60)s left")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct IssuesView: View {
    let model: MountliAppModel
    @State private var confirmingVaultReset = false
    @State private var renamingIssue: IssueRecord?
    @State private var duplicateRename = ""

    private var hasNoIssues: Bool {
        model.durableIssues.isEmpty
            && model.domainIssues.isEmpty
            && model.policyIssues.isEmpty
            && model.vaultRecoveryCandidate == nil
            && !model.vaultResetRequired
            && model.operationalStates.values.allSatisfy { $0.lastErrorCode == nil }
    }
    var body: some View {
        Group {
            if hasNoIssues {
                ContentUnavailableView(
                    "No issues",
                    systemImage: "checkmark.shield",
                    description: Text("All configured locations are healthy.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("issues-empty-state")
            } else {
                List {
                    if let candidate = model.vaultRecoveryCandidate {
                        Section("Vault recovery") {
                            Label("The primary vault failed its integrity check.", systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.red)
                            Text("A verified backup from revision \(candidate.revision) is available.").font(.caption).foregroundStyle(.secondary)
                            Button("Restore verified backup") { model.run { try await model.restoreVaultBackup() } }
                        }
                    }
                    if model.vaultResetRequired {
                        Section("Vault key unavailable") {
                            Text("Encrypted configuration cannot be recovered without the original device-only key.")
                            Button("Reset inaccessible vault", role: .destructive) { confirmingVaultReset = true }
                        }
                    }
                    ForEach(model.durableIssues) { issue in
                        let mount = issue.mountID.flatMap { id in model.mounts.first { $0.id == id } }
                        IssueCard(
                            title: issue.message,
                            code: issue.diagnosticCode,
                            mount: mount,
                            model: model,
                            createdAt: issue.createdAt,
                            remotePath: issue.remotePath,
                            redactedPathToken: issue.redactedPathToken
                        ) {
                            ForEach(issue.suggestedActions, id: \.self) { action in
                                resolutionButton(issue, action: action)
                            }
                        }
                    }
                    ForEach(model.domainIssues, id: \.self) { issue in
                        if issue.hasPrefix("missing:"), let mount = model.mounts.first(where: { issue.hasSuffix($0.domainIdentifier) }) {
                            IssueCard(title: "\(mount.displayName) is missing from Finder & Files", code: "DOMAIN_MISSING", mount: mount, model: model) {
                                Button("Restore") { model.run { try await model.restoreDomain(mount) } }
                            }
                        } else {
                            IssueCard(title: "Unrecognized File Provider domain", code: issue, mount: nil, model: model) { EmptyView() }
                        }
                    }
                    ForEach(model.policyIssues) { issue in
                        IssueCard(
                            title: issue.impact, code: issue.diagnosticCode, mount: issue.mountID.flatMap { id in model.mounts.first { $0.id == id } },
                            model: model
                        ) { EmptyView() }
                    }
                    ForEach(Array(model.operationalStates.values), id: \.mountID) { state in
                        if let code = state.lastErrorCode,
                            !model.durableIssues.contains(where: { $0.mountID == state.mountID && $0.diagnosticCode == code }),
                            let mount = model.mounts.first(where: { $0.id == state.mountID })
                        {
                            IssueCard(title: issueImpact(code), code: code, mount: mount, model: model) {
                                if let remote = model.remotes.first(where: { $0.id == mount.remoteID }), code.localizedCaseInsensitiveContains("auth") {
                                    Button("Reconnect") { model.run { try await model.reconnect(remote) } }
                                } else {
                                    Button("Retry") { model.run { try await model.refresh(mount) } }
                                }
                                if code.localizedCaseInsensitiveContains("conflict") || code.localizedCaseInsensitiveContains("duplicate") {
                                    Button("Review in \(Self.filesLabel)") { model.run { try await model.reveal(mount) } }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Issues")
        .confirmationDialog("Reset inaccessible vault?", isPresented: $confirmingVaultReset, titleVisibility: .visible) {
            Button("Reset vault and remove locations", role: .destructive) { model.run { try await model.resetVaultAfterKeyLoss() } }
        } message: {
            Text("This cannot recover or decrypt the previous configuration.")
        }
        .alert(
            "Rename exact duplicate",
            isPresented: Binding(
                get: { renamingIssue != nil },
                set: { if !$0 { renamingIssue = nil } }
            )
        ) {
            TextField("New name", text: $duplicateRename)
            Button("Rename") {
                if let issue = renamingIssue {
                    Task { await model.requestIssueResolution(issue, action: .renameDuplicate, renameTo: duplicateRename) }
                }
                renamingIssue = nil
            }
            .disabled(duplicateRename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renamingIssue = nil }
        } message: {
            Text("MOUNTLI will relist and match the provider’s stable object ID before renaming anything.")
        }
        .sheet(item: issueBinding) { issue in
            IssueDetailView(model: model, issue: issue)
        }
        .task { await model.refreshActivity() }
        .refreshable { await model.refreshActivity() }
    }

    private var issueBinding: Binding<IssueRecord?> {
        Binding(
            get: {
                model.requestedIssueID.flatMap { id in
                    model.durableIssues.first { $0.id == id }
                }
            },
            set: { if $0 == nil { model.requestedIssueID = nil } }
        )
    }

    @ViewBuilder
    private func resolutionButton(_ issue: IssueRecord, action: IssueResolutionAction) -> some View {
        switch action {
        case .retry:
            Button("Retry") { Task { await model.requestIssueResolution(issue, action: .retry) } }
        case .reconnect:
            Button("Reconnect") { Task { await model.requestIssueResolution(issue, action: .reconnect) } }
        case .deleteAnyway:
            Button("Delete Anyway", role: .destructive) {
                Task { await model.requestIssueResolution(issue, action: .deleteAnyway) }
            }
        case .keepRemote:
            Button("Keep Remote") { Task { await model.requestIssueResolution(issue, action: .keepRemote) } }
        case .deleteDuplicate:
            if issue.remoteObjectID != nil {
                Button("Delete Exact Duplicate", role: .destructive) {
                    Task { await model.requestIssueResolution(issue, action: .deleteDuplicate) }
                }
            }
        case .renameDuplicate:
            if issue.remoteObjectID != nil {
                Button("Rename Exact Duplicate") {
                    duplicateRename = issue.defaultRename ?? ""
                    renamingIssue = issue
                }
            }
        }
    }

    private func issueImpact(_ code: String) -> String {
        if code.localizedCaseInsensitiveContains("auth") { return "Authentication is required before this mount can sync." }
        if code.localizedCaseInsensitiveContains("quota") { return "The provider reports insufficient storage quota." }
        if code.localizedCaseInsensitiveContains("conflict") { return "Remote and local changes conflicted; MOUNTLI kept both versions." }
        if code.localizedCaseInsensitiveContains("duplicate") { return "The provider returned duplicate names that need review." }
        return "This mount could not complete its most recent sync operation."
    }

    private static var filesLabel: String {
        #if os(macOS)
            "Finder"
        #else
            "Files"
        #endif
    }
}

private struct IssueCard<Actions: View>: View {
    let title: String
    let code: String
    let mount: MountDefinition?
    let model: MountliAppModel
    let createdAt: Date?
    let remotePath: String?
    let redactedPathToken: String?
    let actions: () -> Actions
    @State private var showingSensitivePath = false

    init(
        title: String,
        code: String,
        mount: MountDefinition?,
        model: MountliAppModel,
        createdAt: Date? = nil,
        remotePath: String? = nil,
        redactedPathToken: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.code = code
        self.mount = mount
        self.model = model
        self.createdAt = createdAt
        self.remotePath = remotePath
        self.redactedPathToken = redactedPathToken
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            if let mount { LabeledContent("Mount", value: mount.displayName) }
            if let createdAt {
                LabeledContent("Reported") { Text(createdAt, format: .dateTime) }
                    .font(.caption)
            }
            if let remotePath {
                if showingSensitivePath {
                    LabeledContent("Remote path", value: remotePath)
                } else {
                    LabeledContent("Affected item", value: redactedPathToken ?? "Hidden")
                    Button("Reveal Sensitive Path") { showingSensitivePath = true }
                }
            }
            Text(code).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                actions()
                Button("Copy Support Details") {
                    copy("MOUNTLI issue \(code)\nMount: \(mount?.id.uuidString.lowercased() ?? "none")")
                }
            }
        }.padding(.vertical, 4)
    }

    private func copy(_ value: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        #else
            UIPasteboard.general.string = value
        #endif
    }
}

private struct IssueDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let model: MountliAppModel
    let issue: IssueRecord

    private var mount: MountDefinition? {
        issue.mountID.flatMap { id in model.mounts.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Impact") {
                    Text(issue.message)
                    LabeledContent("Type", value: issue.kind.rawValue)
                    LabeledContent("Reported") { Text(issue.createdAt, format: .dateTime) }
                    if let mount { LabeledContent("Mount", value: mount.displayName) }
                }
                Section("Support") {
                    LabeledContent("Diagnostic code", value: issue.diagnosticCode)
                    LabeledContent("Issue ID", value: issue.id.uuidString.lowercased())
                    if let token = issue.redactedPathToken {
                        LabeledContent("Affected item", value: token)
                    }
                    Button("Copy Support Details") {
                        let details =
                            "MOUNTLI issue \(issue.diagnosticCode)\nIssue: \(issue.id.uuidString.lowercased())\nMount: \(issue.mountID?.uuidString.lowercased() ?? "none")"
                        #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(details, forType: .string)
                        #else
                            UIPasteboard.general.string = details
                        #endif
                    }
                }
            }
            .navigationTitle("Issue Detail")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 500, minHeight: 420)
        #endif
    }
}

struct RemoteFolderPicker: View {
    @Environment(\.dismiss) private var dismiss
    let model: MountliAppModel
    let remote: RemoteProfile
    @Binding var selection: String
    @State private var directory = ""
    @State private var folders: [RemoteItem] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if !directory.isEmpty {
                    Button("Go to Parent", systemImage: "arrow.up") {
                        directory = parent(of: directory)
                        load()
                    }
                }
                if loading { ProgressView("Loading folders…") }
                ForEach(folders) { folder in
                    Button {
                        directory = folder.path
                        load()
                    } label: {
                        Label(folder.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            .navigationTitle(directory.isEmpty ? remote.displayName : directory)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose This Folder") {
                        selection = directory
                        dismiss()
                    }
                }
            }
            .task {
                directory = selection
                load()
            }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private func load() {
        loading = true
        error = nil
        Task {
            do { folders = try await model.listFolders(remoteID: remote.id, directory: directory) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
    private func parent(of value: String) -> String { value.split(separator: "/").dropLast().joined(separator: "/") }
}

private struct MountWizard: View {
    @Environment(\.dismiss) private var dismiss
    let model: MountliAppModel
    @State private var remoteID: UUID?
    @State private var name = ""
    @State private var root = ""
    @State private var readOnly = false
    @State private var capabilities: BackendCapabilities?
    @State private var quota: QuotaUsage?
    @State private var saving = false
    @State private var probing = false
    @State private var showingDirectoryImporter = false
    @State private var showingRemoteBrowser = false
    @State private var localDirectory: URL?

    private var remote: RemoteProfile? { remoteID.flatMap { id in model.remotes.first { $0.id == id } } }
    private var usesLocalDirectory: Bool { remote?.backendType == "local" }
    private var forcedReadOnly: Bool { capabilities?.readOnly == true || model.managedPolicy.forceReadOnly }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote") {
                    Picker("Remote", selection: $remoteID) {
                        Text("Choose a remote").tag(UUID?.none)
                        ForEach(model.remotes) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                }
                Section("Location") {
                    TextField("Name in Finder & Files", text: $name)
                    if usesLocalDirectory {
                        Button("Choose Local Folder…", systemImage: "folder.badge.plus") { showingDirectoryImporter = true }
                        if let localDirectory { LabeledContent("Folder", value: localDirectory.lastPathComponent) }
                    } else {
                        HStack {
                            TextField("Remote subfolder", text: $root)
                            Button("Browse…") { showingRemoteBrowser = true }.disabled(remote == nil)
                        }
                    }
                    Toggle("Read only", isOn: $readOnly).disabled(forcedReadOnly)
                    if forcedReadOnly { Text("Read only is required by backend capabilities or managed policy.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Capability check") {
                    Button(probing ? "Checking…" : "Check Connection and Capabilities") { probe() }.disabled(remoteID == nil || probing)
                    if let capabilities {
                        LabeledContent("Write access", value: capabilities.readOnly ? "Unavailable" : "Available")
                        LabeledContent("Server-side move", value: capabilities.serverSideMove ? "Available" : "Unavailable")
                        if capabilities.reportsQuota {
                            if let quota {
                                LabeledContent(
                                    "Used", value: quota.used.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable")
                                LabeledContent(
                                    "Free", value: quota.free.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable")
                            } else {
                                LabeledContent("Quota", value: "Unavailable")
                            }
                        } else {
                            LabeledContent("Quota", value: "Not reported by this backend")
                        }
                    }
                }
            }
            .navigationTitle("Add Mount")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add") { add() }
                        .disabled(
                            remoteID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || capabilities == nil
                                || usesLocalDirectory && localDirectory == nil)
                }
            }
            .onChange(of: remoteID) { _, id in
                if let id, name.isEmpty { name = model.remotes.first { $0.id == id }?.displayName ?? "" }
                localDirectory = nil
                root = ""
                capabilities = nil
                quota = nil
            }
            .fileImporter(isPresented: $showingDirectoryImporter, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    localDirectory = url
                    root = url.standardizedFileURL.path
                    probe()
                case .failure(let error): model.presentedError = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingRemoteBrowser) {
                if let remote { RemoteFolderPicker(model: model, remote: remote, selection: $root) }
            }
            .onChange(of: root) { _, _ in
                capabilities = nil
                quota = nil
            }
        }
        #if os(macOS)
            .frame(minWidth: 500, minHeight: 500)
        #endif
    }

    private func probe() {
        guard let remoteID else { return }
        probing = true
        Task {
            let scoped = localDirectory?.startAccessingSecurityScopedResource() == true
            defer { if scoped { localDirectory?.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await model.probeMount(remoteID: remoteID, root: root)
                capabilities = result
                quota = result.reportsQuota ? try? await model.quota(remoteID: remoteID, root: root) : nil
                if result.readOnly || model.managedPolicy.forceReadOnly { readOnly = true }
            } catch { model.presentedError = error.localizedDescription }
            probing = false
        }
    }

    private func add() {
        guard let remoteID else { return }
        saving = true
        Task {
            let scoped = localDirectory?.startAccessingSecurityScopedResource() == true
            defer { if scoped { localDirectory?.stopAccessingSecurityScopedResource() } }
            do {
                let latest = try await model.probeMount(remoteID: remoteID, root: root)
                try await model.addMount(remoteID: remoteID, name: name, root: root, readOnly: readOnly || latest.readOnly, localDirectory: localDirectory)
                dismiss()
            } catch {
                model.presentedError = error.localizedDescription
                saving = false
            }
        }
    }
}

extension NetworkPolicy {
    fileprivate var label: String {
        switch self {
        case .allNetworks: "All networks"
        case .wifiOnly: "Wi-Fi only"
        case .avoidConstrained: "Avoid constrained networks"
        }
    }
}

extension OperationKind {
    fileprivate var label: String {
        switch self {
        case .enumerate: "Enumerating folder"
        case .download: "Downloading file"
        case .upload: "Uploading file"
        case .createDirectory: "Creating folder"
        case .move: "Moving item"
        case .delete: "Deleting item"
        case .refresh: "Refreshing mount"
        }
    }
    fileprivate var systemImage: String {
        switch self {
        case .enumerate, .refresh: "arrow.clockwise"
        case .download: "arrow.down.circle"
        case .upload: "arrow.up.circle"
        case .createDirectory: "folder.badge.plus"
        case .move: "arrow.turn.up.right"
        case .delete: "trash"
        }
    }
}

extension OperationOutcome {
    fileprivate var label: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .succeeded: "Complete"
        case .retryableFailure: "Retrying"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
