import MountliCore
import SwiftUI
import UniformTypeIdentifiers

struct RemoteWizard: View {
    @Environment(\.dismiss) private var dismiss
    let model: MountliAppModel
    let editing: RemoteProfile?
    @State private var search = ""
    @State private var selected: ProviderDescriptor?
    @State private var displayName = ""
    @State private var advanced = false
    @State private var step: ConfigurationStep?
    @State private var answer = ""
    @State private var working = false
    @State private var localError: String?
    @State private var showingResourceImporter = false
    @State private var resources: [ManagedResourceReference]
    @State private var saved = false
    @State private var cryptBaseEngineName: String
    @State private var cryptRoot: String
    @State private var cryptFilenameEncryption: CryptDraft.FilenameEncryption
    @State private var cryptEncryptDirectoryNames: Bool
    @State private var cryptPassword = ""
    @State private var cryptSecondPassword: String
    @State private var cryptPasswordAcknowledged: Bool
    @State private var showingCryptBrowser = false

    private let curated = [
        "drive", "onedrive", "dropbox", "s3", "webdav", "sftp", "smb", "box", "b2", "azureblob", "azurefiles", "pcloud", "protondrive", "crypt",
    ]

    init(model: MountliAppModel, editing: RemoteProfile? = nil) {
        self.model = model
        self.editing = editing
        _displayName = State(initialValue: editing?.displayName ?? "")
        _resources = State(initialValue: editing?.resources ?? [])
        let remoteValue = editing?.options["remote"] ?? ""
        let split = remoteValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        _cryptBaseEngineName = State(initialValue: split.first.map(String.init) ?? "")
        _cryptRoot = State(initialValue: split.count > 1 ? String(split[1]) : "")
        _cryptFilenameEncryption = State(
            initialValue: CryptDraft.FilenameEncryption(
                rawValue: editing?.options["filename_encryption"] ?? "standard"
            ) ?? .standard
        )
        _cryptEncryptDirectoryNames = State(
            initialValue: editing?.options["directory_name_encryption"] != "false"
        )
        _cryptSecondPassword = State(
            initialValue: editing == nil ? CryptDraft.generateSecondPassword() : ""
        )
        _cryptPasswordAcknowledged = State(initialValue: editing != nil)
    }

    private var filtered: [ProviderDescriptor] {
        guard !search.isEmpty else { return model.catalog }
        return model.catalog.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.description.localizedCaseInsensitiveContains(search)
                || $0.aliases.contains(where: { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private var activeResourceRequirementKind: String? {
        guard let optionName = step?.option?.name, let backendType = selected?.name else { return nil }
        return model.resourceRequirementKind(optionName: optionName, backendType: backendType)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let step {
                    question(step)
                } else if let selected {
                    selected.name == "crypt" ? AnyView(cryptNaming(selected)) : AnyView(naming(selected))
                } else {
                    catalog
                }
            }
            .navigationTitle(editing == nil ? "Add Remote" : "Edit Remote")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task { await model.cancelActiveConfiguration() }
                        dismiss()
                    }
                }
                if editing == nil, selected != nil, step == nil {
                    ToolbarItem(placement: .navigation) {
                        Button("Back", systemImage: "chevron.backward") { selected = nil }
                            .disabled(working)
                    }
                }
            }
        }
        .task {
            if let editing, selected == nil {
                selected = model.catalog.first { $0.name == editing.backendType }
            }
        }
        #if os(macOS)
            .frame(
                minWidth: 620,
                idealWidth: 720,
                maxWidth: 900,
                minHeight: 620,
                idealHeight: 760,
                maxHeight: 900
            )
        #else
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        #endif
        .sheet(
            isPresented: Binding(
                get: { localError != nil },
                set: { if !$0 { localError = nil } }
            )
        ) {
            ActionFailureView(
                title: "Configuration failed",
                message: localError ?? "Unknown error",
                dismiss: { localError = nil }
            )
        }
        .fileImporter(
            isPresented: $showingResourceImporter,
            allowedContentTypes: activeResourceRequirementKind == "managedDirectory" ? [.folder] : [.data]
        ) { result in
            importResource(result)
        }
        .onDisappear {
            guard !saved else { return }
            let originalIDs = Set(editing?.resources.map(\.id) ?? [])
            let staged = resources.filter { !originalIDs.contains($0.id) }
            Task {
                await model.cancelActiveConfiguration()
                await model.discardConfigurationResources(staged)
            }
        }
    }

    private var catalog: some View {
        List {
            Section("Popular") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(curated.compactMap { key in model.catalog.first { $0.name == key } }) { provider in
                        Button {
                            selected = provider
                            displayName = provider.description
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ProviderCardIcon(type: provider.name)
                                Text(provider.description)
                                    .font(.headline)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(provider.name).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("All rclone backends") {
                ForEach(filtered) { provider in
                    Button {
                        selected = provider
                        displayName = provider.description
                    } label: {
                        HStack {
                            ProviderCardIcon(type: provider.name)
                            VStack(alignment: .leading) {
                                Text(provider.description).foregroundStyle(.primary)
                                Text(provider.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $search, prompt: "Search all backends")
    }

    private func naming(_ provider: ProviderDescriptor) -> some View {
        Form {
            Section("Remote") {
                LabeledContent("Backend", value: provider.description)
                TextField("Display name", text: $displayName)
                Toggle("Show advanced questions", isOn: $advanced)
            }
            Section {
                Label("Credentials are stored only in MOUNTLI’s encrypted local vault.", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("Continue") { start(provider) }
                    .buttonStyle(.borderedProminent)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
        }
    }

    private func cryptNaming(_ provider: ProviderDescriptor) -> some View {
        Form {
            Section("Crypt remote") {
                LabeledContent("Backend", value: provider.description)
                TextField("Display name", text: $displayName)
                Picker("Base remote", selection: $cryptBaseEngineName) {
                    Text("Choose a remote").tag("")
                    ForEach(model.remotes.filter { $0.id != editing?.id }) { remote in
                        Text(remote.displayName).tag(remote.engineName)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        TextField("Dedicated encrypted root", text: $cryptRoot)
                        Button("Browse…") { showingCryptBrowser = true }
                            .disabled(cryptBaseEngineName.isEmpty)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Dedicated encrypted root", text: $cryptRoot)
                        Button("Browse…") { showingCryptBrowser = true }
                            .disabled(cryptBaseEngineName.isEmpty)
                    }
                }
            }
            Section("Name encryption") {
                Picker("File names", selection: $cryptFilenameEncryption) {
                    Text("Standard").tag(CryptDraft.FilenameEncryption.standard)
                    Text("Obfuscate").tag(CryptDraft.FilenameEncryption.obfuscate)
                    Text("Off").tag(CryptDraft.FilenameEncryption.off)
                }
                Toggle("Encrypt directory names", isOn: $cryptEncryptDirectoryNames)
            }
            Section("Encryption passwords") {
                SecureField(
                    editing == nil ? "Long passphrase (at least 12 characters)" : "New passphrase (leave blank to keep current)",
                    text: $cryptPassword
                )
                if editing == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Generated second password")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(cryptSecondPassword)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("crypt-generated-password")
                    }
                    Toggle("I saved the generated second password", isOn: $cryptPasswordAcknowledged)
                } else {
                    SecureField("New second password (leave blank to keep current)", text: $cryptSecondPassword)
                }
                Label(
                    "Changing either password does not re-encrypt existing data and can make it permanently unreadable.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button("Continue") { startCrypt(provider) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("crypt-continue")
                    .disabled(
                        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || cryptBaseEngineName.isEmpty
                            || editing == nil && (cryptPassword.count < 12 || !cryptPasswordAcknowledged)
                            || working
                    )
            }
        }
        .sheet(isPresented: $showingCryptBrowser) {
            if let base = model.remotes.first(where: { $0.engineName == cryptBaseEngineName }) {
                RemoteFolderPicker(model: model, remote: base, selection: $cryptRoot)
            }
        }
    }

    private func startCrypt(_ provider: ProviderDescriptor) {
        working = true
        Task {
            do {
                let options: [String: String]
                if let editing {
                    var updated = editing.options
                    updated["remote"] = "\(cryptBaseEngineName):\(cryptRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
                    updated["filename_encryption"] = cryptFilenameEncryption.rawValue
                    updated["directory_name_encryption"] = cryptEncryptDirectoryNames ? "true" : "false"
                    if !cryptPassword.isEmpty { updated["password"] = cryptPassword }
                    if !cryptSecondPassword.isEmpty { updated["password2"] = cryptSecondPassword }
                    options = updated
                } else {
                    options = try CryptDraft(
                        baseEngineName: cryptBaseEngineName,
                        root: cryptRoot,
                        filenameEncryption: cryptFilenameEncryption,
                        encryptDirectoryNames: cryptEncryptDirectoryNames,
                        password: cryptPassword,
                        secondPassword: cryptSecondPassword,
                        acknowledgedSecondPassword: cryptPasswordAcknowledged
                    ).rawOptions()
                }
                let profile = editing ?? RemoteProfile.make(displayName: displayName, backendType: provider.name)
                let next = try await model.configuration.start(
                    engineName: profile.engineName,
                    backendType: provider.name,
                    initialOptions: options,
                    advanced: advanced
                )
                step = next
                model.trackConfigurationSession(next.sessionID)
            } catch {
                localError = error.localizedDescription
            }
            working = false
        }
    }

    @ViewBuilder
    private func question(_ step: ConfigurationStep) -> some View {
        if step.status == .complete {
            ProgressView("Saving remote…").task { await finish(step) }
        } else if let option = step.option {
            Form {
                Section(option.required ? "Required" : "Configuration") {
                    if option.exclusive, !option.examples.isEmpty {
                        Picker(option.name, selection: $answer) {
                            if !option.required { Text("Default").tag("") }
                            ForEach(option.examples, id: \.value) { example in
                                Text(example.help.isEmpty ? example.value : example.help).tag(example.value)
                            }
                        }
                    } else if option.valueType.localizedCaseInsensitiveContains("bool") {
                        Toggle(
                            option.name,
                            isOn: Binding(
                                get: { ["true", "1", "yes"].contains(answer.lowercased()) },
                                set: { answer = $0 ? "true" : "false" }
                            ))
                    } else if option.isPassword || option.sensitive {
                        SecureField(option.name, text: $answer)
                    } else {
                        TextField(option.name, text: $answer)
                    }
                    if let provider = selected, model.isFileBackedOption(option, backendType: provider.name) {
                        Button("Choose Protected Resource…", systemImage: "doc.badge.plus") {
                            showingResourceImporter = true
                        }
                    }
                    if !option.help.isEmpty {
                        Text(option.help)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = step.message, !message.isEmpty {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if !option.examples.isEmpty, !option.exclusive {
                    Section("Suggestions") {
                        ForEach(option.examples, id: \.value) { example in
                            Button {
                                answer = example.value
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(example.help.isEmpty ? example.value : example.help)
                                    if !example.help.isEmpty {
                                        Text(example.value)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Section {
                    Button("Continue") { submit(step) }
                        .buttonStyle(.borderedProminent)
                        .disabled(option.required && answer.isEmpty || working)
                }
            }
            .onAppear { if answer.isEmpty { answer = option.defaultValue } }
            .onChange(of: step.state) { _, _ in answer = step.option?.defaultValue ?? "" }
        } else {
            ContentUnavailableView("Invalid configuration response", systemImage: "exclamationmark.triangle")
        }
    }

    private func start(_ provider: ProviderDescriptor) {
        let profile = editing ?? RemoteProfile.make(displayName: displayName, backendType: provider.name)
        working = true
        Task {
            do {
                if let editing {
                    step = try await model.configuration.start(
                        engineName: editing.engineName,
                        backendType: provider.name,
                        initialOptions: editing.options,
                        advanced: advanced
                    )
                } else {
                    step = try await model.configuration.start(
                        engineName: profile.engineName,
                        backendType: provider.name,
                        advanced: advanced
                    )
                }
                if let sessionID = step?.sessionID {
                    model.trackConfigurationSession(sessionID)
                }
                working = false
            } catch {
                localError = error.localizedDescription
                working = false
            }
        }
    }

    private func submit(_ current: ConfigurationStep) {
        working = true
        Task {
            do {
                step = try await model.configuration.continueConfiguration(sessionID: current.sessionID, answer: answer)
                model.trackConfigurationSession(step?.sessionID)
                answer = step?.option?.defaultValue ?? ""
                working = false
            } catch {
                localError = error.localizedDescription
                working = false
            }
        }
    }

    private func finish(_ completed: ConfigurationStep) async {
        guard let provider = selected, let options = completed.options else { return }
        do {
            try await model.saveRemote(
                displayName: displayName,
                backendType: completed.backendType ?? provider.name,
                options: options,
                resources: resources,
                replacing: editing?.id
            )
            model.trackConfigurationSession(nil)
            saved = true
            dismiss()
        } catch {
            model.trackConfigurationSession(nil)
            localError = error.localizedDescription
            step = nil
        }
    }

    private func importResource(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result, let optionName = step?.option?.name else {
            if case .failure(let error) = result { localError = error.localizedDescription }
            return
        }
        working = true
        Task {
            do {
                let imported = try await model.importConfigurationResource(
                    from: url,
                    optionName: optionName,
                    requirementKind: activeResourceRequirementKind
                )
                resources.append(imported.reference)
                answer = imported.path
                working = false
            } catch {
                localError = error.localizedDescription
                working = false
            }
        }
    }
}

private struct ProviderCardIcon: View {
    let type: String

    private var symbol: String {
        switch type {
        case "crypt": "lock.fill"
        case "sftp", "ftp", "smb", "webdav", "http", "nfs", "hdfs": "server.rack"
        case "s3", "b2", "azureblob", "azurefiles", "swift", "gcs", "oracleobjectstorage", "qingstor", "storj": "shippingbox.fill"
        case "local": "internaldrive.fill"
        case "alias", "union", "combine", "chunker", "compress", "hasher", "cache": "square.stack.3d.up.fill"
        case "protondrive": "shield.lefthalf.filled"
        default: "cloud.fill"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(Color.mountliEmerald)
            .frame(width: 30, height: 30)
            .background(Color.mountliEmerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
