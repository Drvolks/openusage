import Foundation

struct DeepSeekAuth: Hashable, Sendable {
    var apiKey: String
}

enum DeepSeekAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No DeepSeek API key. Set DEEPSEEK_API_KEY or add it to ~/.config/openusage/deepseek.json."
        case .invalidKey:
            return "DeepSeek API key invalid. Check your key at platform.deepseek.com/api_keys."
        case .saveFailed:
            return "Couldn't save the DeepSeek API key."
        case .deleteFailed:
            return "Couldn't remove the saved DeepSeek API key."
        }
    }
}

/// Reads a [DeepSeek](https://platform.deepseek.com) API key the user has already placed on the
/// machine. Like OpenRouter and Z.ai, DeepSeek has no companion CLI/app that stashes a credential in a
/// known spot, so the key comes from an environment variable or a small config file. A GUI app
/// launched from Finder/Dock doesn't inherit the interactive shell environment, so
/// `ProcessEnvironmentReader` captures the login shell's environment at launch (see
/// `LoginShellEnvironment`) — an env var exported in a shell profile is honored even in a packaged
/// build; the config file remains the explicit path.
struct DeepSeekAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/deepseek.json",
        "~/.config/deepseek/key.json"
    ]
    /// Environment variables checked in order. `DEEPSEEK_API_KEY` is the name DeepSeek's own docs and
    /// SDKs use; `DEEPSEEK_TOKEN` is accepted as a fallback some tools export.
    static let environmentNames = ["DEEPSEEK_API_KEY", "DEEPSEEK_TOKEN"]

    /// Opt-in starting balance, in the account's own currency, that turns the balance readout into a
    /// meter. DeepSeek's API reports only what's left — it has no concept of "what you started with" —
    /// so the ceiling can only come from the user.
    static let initialBalanceEnvironmentName = "DEEPSEEK_INITIAL_BALANCE"

    private let store: UserAPIKeyStore
    private let environment: EnvironmentReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.environment = environment
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { DeepSeekAuthError($0) }
        )
    }

    func loadAPIKey() -> DeepSeekAuth? { store.loadKey().map(DeepSeekAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }

    /// The user-declared starting balance, or `nil` when it isn't set (or isn't a positive number).
    /// Read from the environment only: the config file is rewritten wholesale whenever Settings saves a
    /// key, so a value parked there would be silently dropped.
    func loadInitialBalance() -> Double? {
        guard let raw = environment.value(for: Self.initialBalanceEnvironmentName) else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(cleaned), value.isFinite, value > 0 else {
            if !cleaned.isEmpty {
                AppLog.warn(.config, "\(Self.initialBalanceEnvironmentName) is not a positive number — ignoring")
            }
            return nil
        }
        return value
    }
}
