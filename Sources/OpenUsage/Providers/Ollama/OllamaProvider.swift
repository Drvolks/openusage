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
            //
            // Deliberately not `isUsagePeriod`: that marks a row where $0.00 means nothing was used, and
            // this row counts charges *beyond* the plan. A subscriber can run Ollama hard all month and
            // still sit at $0.00, so the "No usage in this period" hover would be plainly wrong.
            .values(id: "ollama.last4Weeks", provider: provider, title: "Last 4 Weeks",
                    metricLabel: "Last 4 Weeks", selection: .kind(.dollars),
                    valueWord: "spent")
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
        let account = await loadAccount { try await usageClient.fetchAccount(key: key) }

        var accountBody: Data?
        var warning: String?
        switch account {
        case .success(let body):
            accountBody = body
        case .failure(let error):
            // Best-effort does not mean invisible: without this, a persistently failing plan lookup just
            // looks like an account that has no plan. Log it and carry an amber notice so the missing
            // badge is explained, while the meters below still refresh normally.
            AppLog.warn(.refresh, "ollama plan lookup failed (\(error.errorCategory.rawValue)); meters unaffected")
            warning = "Couldn't read your Ollama plan. Usage below is still up to date."
        }

        switch usage {
        case .success(let body):
            do {
                let mapped = try OllamaUsageMapper.map(usageBody: body, accountBody: accountBody)
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines,
                                             refreshedAt: now(), warning: warning)
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

    /// Run the best-effort account call. It never throws into the snapshot — a transport error or a
    /// non-2xx just means "no plan name this refresh" — but it returns *why* so the caller can log the
    /// failure and warn, rather than letting it disappear.
    private func loadAccount(_ call: () async throws -> HTTPResponse) async -> Result<Data, OllamaUsageError> {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else {
                return .failure(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failure(.connectionFailed)
        }
    }
}

private enum UsageResult {
    case success(Data)
    case authFailure
    case failed(OllamaUsageError)
}
