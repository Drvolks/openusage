import Foundation

struct MiniMaxAuth: Hashable, Sendable {
    var apiKey: String
}

enum MiniMaxAuthError: Error, LocalizedError, Equatable {
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
            return "No MiniMax API key. Set MINIMAX_API_KEY or add it to ~/.config/openusage/minimax.json."
        case .invalidKey:
            return "MiniMax key rejected. The quota endpoint needs your Token Plan key, not a pay-as-you-go API key."
        case .saveFailed:
            return "Couldn't save the MiniMax API key."
        case .deleteFailed:
            return "Couldn't remove the saved MiniMax API key."
        }
    }
}

/// Reads a [MiniMax](https://platform.minimax.io) API key the user has already placed on the machine.
/// Like OpenRouter and Z.ai, MiniMax has no companion CLI/app that stashes a credential in a known
/// spot, so the key comes from an environment variable or a small config file. A GUI app launched from
/// Finder/Dock doesn't inherit the interactive shell environment, so `ProcessEnvironmentReader`
/// captures the login shell's environment at launch (see `LoginShellEnvironment`) — an env var
/// exported in a shell profile is honored even in a packaged build; the config file remains the
/// explicit path.
///
/// The quota endpoint answers to the **Token Plan** (coding plan) key, so the coding-plan env names
/// other tools export are checked before the general `MINIMAX_API_KEY` — on a machine carrying both,
/// the plan key is the one this provider needs.
struct MiniMaxAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/minimax.json",
        "~/.config/minimax/key.json"
    ]
    /// Environment variables checked in order: the coding/Token Plan names first (the key this
    /// provider's endpoint accepts), then the general API key name.
    static let environmentNames = [
        "MINIMAX_CODE_PLAN_KEY",
        "MINIMAX_CODING_API_KEY",
        "MINIMAX_API_KEY"
    ]

    private let store: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { MiniMaxAuthError($0) }
        )
    }

    func loadAPIKey() -> MiniMaxAuth? { store.loadKey().map(MiniMaxAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}
