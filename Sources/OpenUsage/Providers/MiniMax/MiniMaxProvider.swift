import Foundation

@MainActor
final class MiniMaxProvider: ProviderRuntime {
    let provider = Provider(
        id: "minimax",
        displayName: "MiniMax",
        icon: .providerMark("minimax"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://platform.minimax.io/user-center/basic-information"),
            ProviderLink(label: "API Keys", url: "https://platform.minimax.io/user-center/basic-information/interface-key")
        ]
    )

    let authStore: MiniMaxAuthStore
    let usageClient: MiniMaxUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: MiniMaxAuthStore = MiniMaxAuthStore(),
        usageClient: MiniMaxUsageClient = MiniMaxUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "minimax.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "minimax.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a stored or environment-exported API key.
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxAuthError.missingKey)
        }

        do {
            let response = try await usageClient.fetchRemains(apiKey: auth.apiKey)
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: MiniMaxAuthError.invalidKey)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(
                    provider: provider,
                    error: MiniMaxUsageError.requestFailed(response.statusCode)
                )
            }
            let lines = try MiniMaxUsageMapper.map(remainsBody: response.body)
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
        } catch let error as MiniMaxUsageError {
            // MiniMax reports a rejected key as a business-level code on an HTTP 200, so the auth case
            // has to be recovered from the body rather than the status line.
            if MiniMaxUsageMapper.isAuthFailure(error) {
                return ProviderSnapshot.error(provider: provider, error: MiniMaxAuthError.invalidKey)
            }
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxUsageError.connectionFailed)
        }
    }
}

extension MiniMaxProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}
