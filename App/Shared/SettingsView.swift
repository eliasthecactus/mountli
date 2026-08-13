import LocalAuthentication
import MountliCore
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension UTType {
    static let rcloneConfig = UTType(filenameExtension: "conf") ?? .plainText
}

struct ConfigFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.rcloneConfig, .plainText] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct DiagnosticArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct RelinkTarget: Identifiable {
    var id: UUID { reference.id }
    let remoteID: UUID
    let reference: ManagedResourceReference
}

struct SettingsView: View {
    @Bindable var model: MountliAppModel
    @State private var showingExport = false
    @State private var showingImport = false
    @State private var showingDiagnosticsExporter = false
    @State private var diagnosticsDocument = DiagnosticArchiveDocument()
    @State private var working = false
    @State private var relinkTarget: RelinkTarget?
    @State private var showingReset = false
    @State private var showingAcknowledgements = false
    @State private var resetConfirmation = ""

    var body: some View {
        Form {
            Section("General") {
                #if os(macOS)
                    Toggle(
                        "Show status in menu bar",
                        isOn: binding(
                            get: { model.snapshot.document.settings.showMenuBarExtra },
                            set: { try await model.setShowMenuBarExtra($0) }
                        ))
                    Toggle(
                        "Launch at login",
                        isOn: binding(
                            get: { model.snapshot.document.settings.launchAtLogin },
                            set: { try await model.setLaunchAtLogin($0) }
                        ))
                #endif
                Toggle("Action required notifications", isOn: notificationBinding(\.actionRequired))
                Toggle("Transfer completed notifications", isOn: notificationBinding(\.transferCompleted))
            }
            Section("Transfers") {
                Stepper(
                    value: binding(
                        get: { model.effectiveMaximumConcurrentTransfers },
                        set: { try await model.setMaximumConcurrentTransfers($0) }
                    ), in: platformTransferRange
                ) {
                    LabeledContent("Concurrent transfers", value: "\(model.effectiveMaximumConcurrentTransfers)")
                }
                .disabled(model.managedPolicy.maximumConcurrentTransfers != nil)
                if model.managedPolicy.maximumConcurrentTransfers != nil { managedLabel }
                Picker(
                    "Default network",
                    selection: binding(
                        get: { model.managedPolicy.allowCellular ? model.snapshot.document.settings.defaultNetworkPolicy : .wifiOnly },
                        set: { try await model.setDefaultNetworkPolicy($0) }
                    )
                ) {
                    ForEach(NetworkPolicy.allCases, id: \.self) { Text($0.settingsLabel).tag($0) }
                }
                .disabled(!model.managedPolicy.allowCellular)
                if !model.managedPolicy.allowCellular { managedLabel }
                Text("MOUNTLI keeps local dirty copies for File Provider retries; it does not run an unbounded retry loop.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Security") {
                Button("Import rclone.conf…", systemImage: "square.and.arrow.down") { showingImport = true }
                    .disabled(!model.managedPolicy.allowConfigImport || working)
                Button("Export encrypted rclone.conf…", systemImage: "square.and.arrow.up") { showingExport = true }
                    .disabled(!model.managedPolicy.allowConfigExport || model.remotes.isEmpty || working)
                if !model.managedPolicy.allowConfigImport || !model.managedPolicy.allowConfigExport { managedLabel }
                if model.remotes.contains(where: { ManagedPolicy.requestsInsecureTLS($0.options) }) {
                    Label("One or more remotes skip normal TLS verification.", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                }
                if !model.managedPolicy.allowInsecureTLS {
                    Text("Insecure TLS options are blocked by the effective security policy.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !allResources.isEmpty {
                Section("Protected resource files") {
                    ForEach(allResources) { value in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(value.reference.displayName)
                                Text(value.reference.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Relink…") { relinkTarget = RelinkTarget(remoteID: value.remoteID, reference: value.reference) }
                        }
                    }
                }
            }
            Section("Diagnostics") {
                Toggle(
                    "Include file names in diagnostics",
                    isOn: binding(
                        get: { model.snapshot.document.settings.includeFilenamesInDiagnostics },
                        set: { try await model.setIncludeFilenamesInDiagnostics($0) }
                    ))
                Button("Export Diagnostics…", systemImage: "cross.case") { prepareDiagnostics() }.disabled(working)
                Text("Diagnostics omit credentials, raw options, resource files, and file contents. File names are included only when the toggle above is on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Managed Policy") {
                LabeledContent("Read-only enforcement", value: model.managedPolicy.forceReadOnly ? "Required" : "Not required")
                LabeledContent("Cellular access", value: model.managedPolicy.allowCellular ? "Allowed" : "Blocked")
                if model.managedPolicy.forceReadOnly || model.managedPolicy.maximumConcurrentTransfers != nil || !model.managedPolicy.allowCellular {
                    managedLabel
                } else {
                    Text("No managed overrides are active.").foregroundStyle(.secondary)
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("rclone", value: Bundle.main.object(forInfoDictionaryKey: "MOUNTLIRcloneVersion") as? String ?? "1.75.0")
                Link("Privacy Policy", destination: URL(string: "https://benavo.ch/privacy")!)
                Link("Source Code", destination: URL(string: "https://github.com/eliasthecactus/mountli")!)
                Button("License & Acknowledgements…") { showingAcknowledgements = true }
                if let supportURL = model.managedPolicy.supportURL { Link("Organization Support", destination: supportURL) }
            }
            Section("Reset") {
                Button("Reset MOUNTLI…", role: .destructive) { showingReset = true }
                Text("Reset is blocked while any mount has pending or dirty operations.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingExport) { ConfigExportFlow(model: model, selectedRemote: nil) }
        .sheet(isPresented: $showingImport) { ConfigImportFlow(model: model) }
        .sheet(isPresented: $showingAcknowledgements) { AcknowledgementsView() }
        .fileImporter(
            isPresented: Binding(
                get: { relinkTarget != nil },
                set: { if !$0 { relinkTarget = nil } }
            ), allowedContentTypes: relinkTarget?.reference.kind == .securityScopedDirectory ? [.folder] : [.data]
        ) { result in
            guard let target = relinkTarget else { return }
            relinkTarget = nil
            if case .success(let url) = result {
                model.run { try await model.relinkResource(remoteID: target.remoteID, referenceID: target.reference.id, to: url) }
            } else if case .failure(let error) = result {
                model.presentedError = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showingDiagnosticsExporter, document: diagnosticsDocument, contentType: .zip, defaultFilename: "MOUNTLI-Diagnostics") {
            result in
            if case .failure(let error) = result { model.presentedError = error.localizedDescription }
        }
        .alert("Reset MOUNTLI", isPresented: $showingReset) {
            TextField("Type RESET", text: $resetConfirmation)
            Button("Reset", role: .destructive) {
                model.run { try await model.resetMountli() }
            }
            .disabled(resetConfirmation != "RESET")
            Button("Cancel", role: .cancel) { resetConfirmation = "" }
        } message: {
            Text(
                "Export your encrypted configuration first if you need a backup. Reset removes File Provider domains, protected resources, encrypted vault files, and the device-only vault key."
            )
        }
    }

    private var platformTransferRange: ClosedRange<Int> {
        #if os(macOS)
            1...8
        #else
            1...4
        #endif
    }

    private var allResources: [RelinkTarget] {
        model.remotes.flatMap { remote in
            remote.resources.map { RelinkTarget(remoteID: remote.id, reference: $0) }
        }
    }

    private var managedLabel: some View {
        Label("Managed by your organization", systemImage: "building.2.crop.circle").font(.caption).foregroundStyle(.secondary)
    }

    private func binding<Value>(
        get: @escaping @MainActor @Sendable () -> Value,
        set: @escaping @MainActor (Value) async throws -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: { value in model.run { try await set(value) } })
    }

    private func notificationBinding(_ keyPath: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.snapshot.document.settings.notifications[keyPath: keyPath] },
            set: { enabled in
                Task {
                    if enabled {
                        let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
                        guard allowed else {
                            model.presentedError = "Notifications were not enabled in System Settings."
                            return
                        }
                    }
                    var value = model.snapshot.document.settings.notifications
                    value[keyPath: keyPath] = enabled
                    do { try await model.setNotificationSettings(value) } catch { model.presentedError = error.localizedDescription }
                }
            }
        )
    }

    private func prepareDiagnostics() {
        working = true
        Task {
            do {
                let url = try await model.prepareDiagnostics()
                let data = try Data(contentsOf: url)
                await model.finishDiagnostics(url)
                diagnosticsDocument = DiagnosticArchiveDocument(data: data)
                showingDiagnosticsExporter = true
            } catch { model.presentedError = error.localizedDescription }
            working = false
        }
    }
}

private struct BundledLegalDocument: Identifiable {
    var id: URL { url }
    let title: String
    let url: URL
}

private struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    private let documents = Self.loadDocuments()

    var body: some View {
        NavigationStack {
            List(documents) { document in
                NavigationLink(document.title) {
                    LegalDocumentView(document: document)
                }
            }
            .navigationTitle("License & Acknowledgements")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 620, minHeight: 520)
        #endif
    }

    private static func loadDocuments() -> [BundledLegalDocument] {
        var result: [BundledLegalDocument] = []
        if let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) {
            result.append(BundledLegalDocument(title: "MOUNTLI — MIT License", url: license))
        }
        if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") {
            result.append(BundledLegalDocument(title: "Third-Party Notices", url: notices))
        }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("ThirdPartyLicenses", isDirectory: true),
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )
        else { return result }
        for case let url as URL in enumerator {
            guard url.lastPathComponent != ".DS_Store",
                (try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey]).isRegularFile) == true
            else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            result.append(BundledLegalDocument(title: relative, url: url))
        }
        let fixed = result.prefix(2)
        return Array(fixed)
            + result.dropFirst(2).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }
}

private struct LegalDocumentView: View {
    let document: BundledLegalDocument
    var body: some View {
        ScrollView {
            Text((try? String(contentsOf: document.url, encoding: .utf8)) ?? "This bundled license could not be read.")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(document.title)
    }
}

struct ConfigExportFlow: View {
    @Environment(\.dismiss) private var dismiss
    let model: MountliAppModel
    let selectedRemote: RemoteProfile?
    @State private var password = ""
    @State private var confirmation = ""
    @State private var plaintext = false
    @State private var confirmingPlaintext = false
    @State private var working = false
    @State private var showingExporter = false
    @State private var document = ConfigFileDocument()

    var body: some View {
        NavigationStack {
            Form {
                Section("Encrypted export") {
                    SecureField("New export passphrase", text: $password)
                    SecureField("Confirm passphrase", text: $confirmation)
                    Text("The export is rclone-encrypted with this new passphrase. It is separate from provider passwords and cannot be recovered by MOUNTLI.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Format") {
                    LabeledContent("Selected format", value: plaintext ? "Plaintext" : "Encrypted")
                    if plaintext {
                        Label(
                            "Plaintext exposes provider credentials to any app or person that can read the file.", systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                        Button("Use encrypted export instead") { plaintext = false }
                    } else {
                        Button("Export without encryption…", role: .destructive) { confirmingPlaintext = true }
                    }
                }
            }
            .navigationTitle(selectedRemote == nil ? "Export rclone.conf" : "Export \(selectedRemote!.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Preparing…" : "Authenticate & Export") { prepare() }
                        .disabled(working || !plaintext && (password.count < 12 || password != confirmation))
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 390)
        #endif
        .confirmationDialog("Export credentials as plaintext?", isPresented: $confirmingPlaintext, titleVisibility: .visible) {
            Button("I understand — use plaintext", role: .destructive) {
                plaintext = true
                password = ""
                confirmation = ""
            }
            Button("Keep encrypted", role: .cancel) {}
        } message: {
            Text("Anyone with this file can read the credentials and tokens for the exported remotes.")
        }
        .fileExporter(isPresented: $showingExporter, document: document, contentType: .rcloneConfig, defaultFilename: "rclone.conf") { result in
            if case .failure(let error) = result { model.presentedError = error.localizedDescription } else { dismiss() }
        }
    }

    private func prepare() {
        working = true
        Task {
            do {
                let context = LAContext()
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Export your MOUNTLI remote configuration")
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mountli-export-\(UUID().uuidString).conf")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await model.exportConfig(to: temporary, password: plaintext ? nil : password, selectedRemote: selectedRemote)
                document = ConfigFileDocument(data: try Data(contentsOf: temporary))
                showingExporter = true
            } catch { model.presentedError = error.localizedDescription }
            working = false
        }
    }
}

struct ConfigImportFlow: View {
    @Environment(\.dismiss) private var dismiss
    let model: MountliAppModel
    @State private var password = ""
    @State private var showingConfigPicker = false
    @State private var imported: ConfigImportResult?
    @State private var currentRequirement: ImportedResourceRequirement?
    @State private var completedRequirements: Set<String> = []
    @State private var resources: [String: [ManagedResourceReference]] = [:]
    @State private var stagedResources: [ManagedResourceReference] = []
    @State private var requirementReferences: [String: ManagedResourceReference] = [:]
    @State private var confirmingReplacement = false
    @State private var working = false
    @State private var committed = false

    private var collisions: [String] {
        guard let imported else { return [] }
        return model.importedCollisions(imported)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let imported {
                    Section("Sections") {
                        ForEach(imported.sections, id: \.engineName) { section in
                            LabeledContent(section.engineName, value: section.backendType)
                        }
                        if !collisions.isEmpty {
                            Label("Collisions: \(collisions.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(
                                "MOUNTLI never renames imported sections because that would break overlay references. Continue only to replace every colliding section atomically."
                            )
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !imported.resourceRequirements.isEmpty {
                        Section("Relink protected resources") {
                            ForEach(imported.resourceRequirements) { requirement in
                                Button {
                                    currentRequirement = requirement
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(requirement.optionName)
                                            Text("\(requirement.engineName) · \(URL(fileURLWithPath: requirement.path).lastPathComponent)")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: completedRequirements.contains(requirement.id) ? "checkmark.circle.fill" : "folder.badge.plus")
                                    }
                                }
                            }
                            Text("Every external file or directory is copied or bookmarked into MOUNTLI’s protected resource store before validation.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("rclone.conf") {
                        SecureField("Config password (only if encrypted)", text: $password)
                        Button("Choose rclone.conf…", systemImage: "doc") { showingConfigPicker = true }
                        Text("MOUNTLI parses without mutating the live vault. Imported section names and overlay references remain exact.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import rclone.conf")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if let imported {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(working ? "Validating…" : collisions.isEmpty ? "Validate & Import" : "Replace All Collisions") {
                            if collisions.isEmpty { commit(imported, policy: .cancel) } else { confirmingReplacement = true }
                        }
                        .disabled(working || completedRequirements.count != imported.resourceRequirements.count)
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 480)
        #endif
        .fileImporter(isPresented: $showingConfigPicker, allowedContentTypes: [.rcloneConfig, .plainText]) { result in
            if case .success(let url) = result { parse(url) } else if case .failure(let error) = result { model.presentedError = error.localizedDescription }
        }
        .fileImporter(
            isPresented: Binding(
                get: { currentRequirement != nil },
                set: { if !$0 { currentRequirement = nil } }
            ), allowedContentTypes: currentRequirement?.kind == "managedDirectory" ? [.folder] : [.data]
        ) { result in
            guard let requirement = currentRequirement else { return }
            currentRequirement = nil
            if case .success(let url) = result {
                relink(url, requirement: requirement)
            } else if case .failure(let error) = result {
                model.presentedError = error.localizedDescription
            }
        }
        .confirmationDialog("Replace all colliding sections?", isPresented: $confirmingReplacement, titleVisibility: .visible) {
            if let imported { Button("Replace All Collisions", role: .destructive) { commit(imported, policy: .replaceAll) } }
            Button("Cancel Import", role: .cancel) {}
        } message: {
            Text("All colliding sections are replaced together, or none are changed. Existing mounts using them must be removed first.")
        }
        .onDisappear {
            guard !committed else { return }
            let values = stagedResources
            Task { await model.discardConfigurationResources(values) }
        }
    }

    private func parse(_ url: URL) {
        working = true
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { imported = try await model.importConfig(from: url, password: password.isEmpty ? nil : password) } catch {
                model.presentedError = error.localizedDescription
            }
            working = false
        }
    }

    private func relink(_ url: URL, requirement: ImportedResourceRequirement) {
        working = true
        Task {
            do {
                let value = try await model.importConfigurationResource(from: url, optionName: requirement.optionName, requirementKind: requirement.kind)
                if let previous = requirementReferences[requirement.id] {
                    resources[requirement.engineName]?.removeAll { $0.id == previous.id }
                    stagedResources.removeAll { $0.id == previous.id }
                    await model.discardConfigurationResources([previous])
                }
                requirementReferences[requirement.id] = value.reference
                stagedResources.append(value.reference)
                resources[requirement.engineName, default: []].append(value.reference)
                if let section = imported?.sections.firstIndex(where: { $0.engineName == requirement.engineName }) {
                    imported?.sections[section].options[requirement.optionName] = value.path
                }
                completedRequirements.insert(requirement.id)
            } catch { model.presentedError = error.localizedDescription }
            working = false
        }
    }

    private func commit(_ value: ConfigImportResult, policy: ImportedRemoteCollisionPolicy) {
        working = true
        Task {
            do {
                try await model.addImportedRemotes(value, resourcesByEngineName: resources, collisionPolicy: policy)
                committed = true
                dismiss()
            } catch {
                model.presentedError = error.localizedDescription
                working = false
            }
        }
    }
}

extension NetworkPolicy {
    fileprivate var settingsLabel: String {
        switch self {
        case .allNetworks: "All networks"
        case .wifiOnly: "Wi-Fi only"
        case .avoidConstrained: "Avoid constrained networks"
        }
    }
}
