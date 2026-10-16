import MountliCore
import SwiftUI

struct OverviewView: View {
    @Bindable var model: MountliAppModel

    private var activeTransfers: Int {
        model.operationalStates.values.reduce(0) { $0 + $1.activeTransfers }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OverviewHero(model: model, activeTransfers: activeTransfers)
                if model.remotes.isEmpty || model.mounts.isEmpty {
                    GettingStartedChecklist(model: model)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    StatTile(title: "Mounts", value: model.mounts.count, systemImage: "externaldrive", section: "Mounts", model: model)
                    StatTile(title: "Remotes", value: model.remotes.count, systemImage: "network", section: "Remotes", model: model)
                    StatTile(
                        title: "Transfers", value: activeTransfers, systemImage: "arrow.up.arrow.down", section: "Activity", model: model,
                        tint: activeTransfers > 0 ? .blue : nil)
                    StatTile(
                        title: "Issues", value: model.unresolvedIssueCount, systemImage: "exclamationmark.triangle", section: "Issues",
                        model: model, tint: model.unresolvedIssueCount > 0 ? .orange : nil)
                }
                if !model.mounts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Locations").font(.headline)
                        ForEach(model.mounts) { mount in
                            MountCard(model: model, mount: mount)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(Color.mountliCanvas)
        .navigationTitle("Overview")
    }
}

private struct OverviewHero: View {
    let model: MountliAppModel
    let activeTransfers: Int

    private enum Phase {
        case loading, noRemotes, noMounts
        case attention(Int)
        case healthy(MountStatus)
    }

    private var phase: Phase {
        if model.isLoading { return .loading }
        if model.remotes.isEmpty { return .noRemotes }
        if model.mounts.isEmpty { return .noMounts }
        if model.unresolvedIssueCount > 0 { return .attention(model.unresolvedIssueCount) }
        return .healthy(model.overallStatus)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            icon
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mountliCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch phase {
        case .loading, .noRemotes, .noMounts: .mountliEmerald
        case .attention: .orange
        case .healthy(let status): status.tint
        }
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .loading: ProgressView().tint(.white)
        case .noRemotes: Image(systemName: "network.badge.shield.half.filled")
        case .noMounts: Image(systemName: "externaldrive.badge.plus")
        case .attention: Image(systemName: "exclamationmark.triangle.fill")
        case .healthy(let status): Image(systemName: activeTransfers > 0 ? "arrow.up.arrow.down" : status.systemImage)
        }
    }

    private var title: String {
        switch phase {
        case .loading: "Loading your configuration…"
        case .noRemotes: "Connect your first storage"
        case .noMounts: "Add a location to \(Self.filesApp)"
        case .attention(let count): count == 1 ? "1 issue needs attention" : "\(count) issues need attention"
        case .healthy(let status):
            activeTransfers > 0
                ? (activeTransfers == 1 ? "1 transfer in progress" : "\(activeTransfers) transfers in progress")
                : status.overviewTitle
        }
    }

    private var subtitle: String {
        switch phase {
        case .loading: "Unlocking the encrypted vault on this device."
        case .noRemotes:
            "A remote is any storage rclone supports: Google Drive, OneDrive, S3, SFTP, WebDAV and many more. "
                + "Credentials stay encrypted on this device."
        case .noMounts: "Pick a remote and a folder. MOUNTLI adds it to \(Self.filesApp) so you can browse it like any other drive."
        case .attention: "Some locations can’t sync until you review them."
        case .healthy:
            model.mounts.count == 1
                ? "Your location is available in \(Self.filesApp)."
                : "All \(model.mounts.count) locations are available in \(Self.filesApp)."
        }
    }

    @ViewBuilder private var actions: some View {
        switch phase {
        case .loading:
            EmptyView()
        case .noRemotes:
            Button("Add a Remote", systemImage: "plus") { model.showingAddRemote = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.catalog.isEmpty)
            Button("Import rclone.conf", systemImage: "square.and.arrow.down") { model.showingConfigImport = true }
                .buttonStyle(.bordered)
                .disabled(!model.managedPolicy.allowConfigImport)
        case .noMounts:
            Button("Add a Mount", systemImage: "externaldrive.badge.plus") { model.showingAddMount = true }
                .buttonStyle(.borderedProminent)
        case .attention:
            Button("Review Issues", systemImage: "arrow.right") { model.requestedSection = "Issues" }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        case .healthy:
            Button("Refresh All", systemImage: "arrow.clockwise") { model.run { try await model.refreshAll() } }
                .buttonStyle(.bordered)
        }
    }

    static var filesApp: String {
        #if os(macOS)
            "Finder"
        #else
            "Files"
        #endif
    }
}

private struct GettingStartedChecklist: View {
    let model: MountliAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Getting started").font(.headline)
            step(1, "Add a remote", detail: "Sign in to a storage provider or import an rclone.conf.", done: !model.remotes.isEmpty) {
                model.showingAddRemote = true
            }
            step(2, "Add a mount", detail: "Choose which remote folder appears in \(OverviewHero.filesApp).", done: !model.mounts.isEmpty) {
                model.showingAddMount = true
            }
            .disabled(model.remotes.isEmpty)
            step(3, "Open it in \(OverviewHero.filesApp)", detail: "Files download on demand and upload when you save.", done: false) {
                if let mount = model.mounts.first { model.run { try await model.reveal(mount) } }
            }
            .disabled(model.mounts.isEmpty)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mountliCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func step(_ number: Int, _ title: String, detail: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(done ? Color.mountliEmerald : Color.secondary.opacity(0.15))
                    if done {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).strikethrough(done, color: .secondary)
                        .foregroundStyle(done ? .secondary : .primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !done { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .accessibilityValue(done ? "Done" : "Not done")
    }
}

private struct StatTile: View {
    let title: String
    let value: Int
    let systemImage: String
    let section: String
    let model: MountliAppModel
    var tint: Color?

    var body: some View {
        Button {
            model.requestedSection = section
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint ?? .mountliEmerald)
                Text(value, format: .number)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(tint ?? .primary)
                    .contentTransition(.numericText())
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.mountliCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityHint("Opens \(section)")
    }
}

private struct MountCard: View {
    let model: MountliAppModel
    let mount: MountDefinition

    private var remote: RemoteProfile? { model.remotes.first { $0.id == mount.remoteID } }
    private var state: MountOperationalState { model.operationalStates[mount.id] ?? MountOperationalState(mountID: mount.id) }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(state.status.tint)
                .frame(width: 40, height: 40)
                .background(state.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(mount.displayName).font(.headline).lineLimit(1)
                Text("\(remote?.displayName ?? "Missing remote")\(mount.root.isEmpty ? "" : " · \(mount.root)")")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            StatusPill(status: state.status)
            Button {
                model.run { try await model.reveal(mount) }
            } label: {
                Label("Open in \(OverviewHero.filesApp)", systemImage: "arrow.up.forward.app")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Open in \(OverviewHero.filesApp)")
        }
        .padding(14)
        .background(Color.mountliCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension MountStatus {
    var tint: Color {
        switch self {
        case .online: .mountliEmerald
        case .connecting, .transferring: .blue
        case .degraded, .authenticationRequired: .orange
        case .offline, .disabled, .paused: .secondary
        case .error: .red
        }
    }

    fileprivate var overviewTitle: String {
        switch self {
        case .online: "Everything is up to date"
        case .connecting: "Connecting…"
        case .transferring: "Syncing"
        case .degraded: "Working with cached data"
        case .offline: "Offline"
        case .authenticationRequired: "Sign-in required"
        case .paused: "Syncing is paused"
        case .disabled: "Locations are disabled"
        case .error: "Something went wrong"
        }
    }
}
