import CryptoKit
import Foundation
import OSLog

public enum MountliLogCategory: String, CaseIterable, Sendable {
    case app
    case vault
    case provider
    case enumeration
    case transfer
    case oauth
    case policy
}

public struct PathTokenizer: Sendable {
    private let key: SymmetricKey

    public init(keyData: Data) {
        precondition(keyData.count >= 32)
        key = SymmetricKey(data: keyData)
    }

    public func token(for path: String) -> String {
        let authentication = HMAC<SHA256>.authenticationCode(for: Data(path.utf8), using: key)
        return authentication.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public typealias MountliLogSink =
    @Sendable (
        _ category: MountliLogCategory,
        _ level: String,
        _ message: String,
        _ createdAt: Date
    ) async -> Void

public struct MountliLogger: Sendable {
    private let logger: Logger
    private let tokenizer: PathTokenizer
    private let category: MountliLogCategory
    private let sink: MountliLogSink?

    public init(
        category: MountliLogCategory,
        tokenizer: PathTokenizer,
        sink: MountliLogSink? = nil
    ) {
        logger = Logger(subsystem: "ch.benavo.mountli", category: category.rawValue)
        self.tokenizer = tokenizer
        self.category = category
        self.sink = sink
    }

    public func info(_ message: String) {
        let safeMessage = DiagnosticsRedactor.redact(message)
        logger.info("\(safeMessage, privacy: .public)")
        buffer(level: "info", message: safeMessage)
    }

    public func notice(_ message: String, path: String?) {
        let safeMessage = DiagnosticsRedactor.redact(message)
        let bufferedMessage: String
        if let path {
            let token = tokenizer.token(for: path)
            bufferedMessage = "\(safeMessage) path-token=\(token)"
            logger.notice("\(safeMessage, privacy: .public) path-token=\(token, privacy: .public)")
        } else {
            bufferedMessage = safeMessage
            logger.notice("\(safeMessage, privacy: .public)")
        }
        buffer(level: "notice", message: bufferedMessage)
    }

    public func error(code: String, message: String, path: String?) {
        let safeCode = DiagnosticsRedactor.redact(code)
        let safeMessage = DiagnosticsRedactor.redact(message)
        let bufferedMessage: String
        if let path {
            let token = tokenizer.token(for: path)
            bufferedMessage = "code=\(safeCode) \(safeMessage) path-token=\(token)"
            logger.error("code=\(safeCode, privacy: .public) \(safeMessage, privacy: .public) path-token=\(token, privacy: .public)")
        } else {
            bufferedMessage = "code=\(safeCode) \(safeMessage)"
            logger.error("code=\(safeCode, privacy: .public) \(safeMessage, privacy: .public)")
        }
        buffer(level: "error", message: bufferedMessage)
    }

    private func buffer(level: String, message: String) {
        guard let sink else { return }
        Task {
            await sink(category, level, message, .now)
        }
    }
}

public enum MountliLogging {
    public static func installLocalKey(
        provider: any KeyMaterialProviding
    ) throws -> Data {
        let key = try provider.loadOrCreateKey()
        return key.withUnsafeBytes { Data($0) }
    }
}
