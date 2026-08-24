import Foundation

@MainActor
final class OllamaProvider: ProviderRuntime {
    let provider = Provider(
        id: "ollama",
        displayName: "Ollama",
        icon: .providerMark("ollama"),
        links: [
            ProviderLink(label: "Usage", url: "https://ollama.com/settings"),
            ProviderLink(label: "API Keys", url: "https://ollama.com/settings/keys")
        ]
    )

    let authStore: OllamaAuthStore
    let usageClient: OllamaUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OllamaAuthStore = OllamaAuthStore(),
        usageClient: OllamaUsageClient = OllamaUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            // Not `isSessionWindow`: that treatment ("Not started" on a fresh pool) needs a reset date,
            // and Ollama publishes none — see `OllamaUsageMapper`.
            .percent(id: "ollama.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "ollama.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            // Ollama reports recent spend as a single rolling four-week total, not a daily history, so
            // this is one unbounded dollar row rather than the Today/Yesterday/Last 30 Days tiles the
            // local-scanner providers ship.
            .values(id: "ollama.last4Weeks", provider: provider, title: "Last 4 Weeks",
                    metricLabel: "Last 4 Weeks", selection: .kind(.dollars),
                    valueWord: "spent", isUsagePeriod: true)
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: the Ollama signing key at `~/.ollama/id_ed25519`. Ollama writes
        // that key on first run, so this answers "Ollama is set up on this Mac" — whether the key is
        // linked to an ollama.com account is only knowable from the network, which a probe must not do.
        // A local-only install therefore enables the provider once and then shows the "Not signed in to
        // Ollama Cloud" notice, which is the honest state rather than a silently missing provider.
        let key = try? await loadOffMainActor { [authStore] in try authStore.loadSigningKey() }
        return (key ?? nil) != nil
    }

    func refresh() async -> ProviderSnapshot {
        let key: OllamaSigningKey?
        do {
            key = try await loadOffMainActor { [authStore] in try authStore.loadSigningKey() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let key else {
            return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.missingKey)
        }

        // The usage endpoint is required; the account endpoint is best-effort (plan name only), so a
        // failure there must not blank out the meters.
        let usage = await load { try await usageClient.fetchUsage(key: key) }
        let account = await loadOptional { try await usageClient.fetchAccount(key: key) }

        switch usage {
        case .success(let body):
            do {
                let mapped = try OllamaUsageMapper.map(usageBody: body, accountBody: account)
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines,
                                             refreshedAt: now())
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            // The key parsed and signed fine, so a 401/403 means ollama.com doesn't know it: the user has
            // Ollama installed but has never run `ollama signin` (or has signed out since).
            return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.notSignedIn)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// Run the required usage call and classify the outcome: the body on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx or transport error.
    private func load(_ call: () async throws -> HTTPResponse) async -> UsageResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    /// Run the optional account call — never throws into the snapshot: a transport error, a non-2xx, or
    /// an auth failure all just mean "no plan name this refresh".
    private func loadOptional(_ call: () async throws -> HTTPResponse) async -> Data? {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else { return nil }
            return response.body
        } catch {
            return nil
        }
    }
}

private enum UsageResult {
    case success(Data)
    case authFailure
    case failed(OllamaUsageError)
}
