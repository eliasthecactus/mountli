import FileProvider
import FileProviderUI
import Foundation

#if os(macOS)
    import AppKit

    final class RecoveryViewController: FPUIActionExtensionViewController {
        private var pendingURL: URL?

        override func loadView() {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
            let label = NSTextField(labelWithString: "Open MOUNTLI to reconnect this location or resolve its sync issue.")
            label.maximumNumberOfLines = 3
            label.alignment = .center
            let button = NSButton(title: "Open MOUNTLI", target: self, action: #selector(openApp))
            let stack = NSStackView(views: [label, button])
            stack.orientation = .vertical
            stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
                stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            ])
            view = root
        }

        override func prepare(forError error: any Error) {
            pendingURL = URL(string: "mountli://recover?code=\((error as NSError).code)")
        }

        override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
            let items = itemIdentifiers.map(\.rawValue).joined(separator: ",")
            pendingURL = URL(string: "mountli://action/\(actionIdentifier)?items=\(items.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }

        @objc private func openApp() {
            if let pendingURL { NSWorkspace.shared.open(pendingURL) }
            extensionContext.completeRequest()
        }
    }
#else
    import UIKit

    final class RecoveryViewController: FPUIActionExtensionViewController {
        private var pendingURL: URL?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let label = UILabel()
            label.text = "Open MOUNTLI to reconnect this location or resolve its sync issue."
            label.numberOfLines = 0
            label.textAlignment = .center
            let button = UIButton(type: .system)
            button.setTitle("Open MOUNTLI", for: .normal)
            button.addTarget(self, action: #selector(openApp), for: .touchUpInside)
            let stack = UIStackView(arrangedSubviews: [label, button])
            stack.axis = .vertical
            stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
                stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
                stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }

        override func prepare(forError error: any Error) {
            pendingURL = URL(string: "mountli://recover?code=\((error as NSError).code)")
        }

        override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
            pendingURL = URL(string: "mountli://action/\(actionIdentifier)")
        }

        @objc private func openApp() {
            guard let pendingURL else { return }
            extensionContext.open(pendingURL) { _ in }
            extensionContext.completeRequest()
        }
    }
#endif
