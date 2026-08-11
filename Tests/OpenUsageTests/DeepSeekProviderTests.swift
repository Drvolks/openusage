import XCTest
@testable import OpenUsage

// MARK: - Sample payloads
/// Mirrors DeepSeek's documented `/user/balance` response (see `docs/providers/deepseek.md`).

private let balanceUSDJSON = #"""
{
  "is_available": true,
  "balance_infos": [
    {
      "currency": "USD",
      "total_balance": "12.50",
      "granted_balance": "2.50",
      "topped_up_balance": "10.00"
    }
  ]
}
"""#

private let balanceCNYJSON = #"""
{
  "is_available": true,
  "balance_infos": [
    {
      "currency": "CNY",
      "total_balance": "110.00",
      "granted_balance": "10.00",
      "topped_up_balance": "100.00"
    }
  ]
}
"""#

/// An account holding both currencies: the USD row is the one shown.
private let balanceBothCurrenciesJSON = #"""
{
  "is_available": true,
  "balance_infos": [
    { "currency": "CNY", "total_balance": "110.00" },
    { "currency": "USD", "total_balance": "4.00" }
  ]
}
"""#

private func data(_ json: String) -> Data {
    Data(json.utf8)
}

// MARK: - DeepSeekAuthStoreTests

final class DeepSeekAuthStoreTests: XCTestCase {
    func testPrefersConfigFileOverEnvironment() {
        // Config file wins so editing it to rotate the key isn't shadowed by a stale env value.
        let store = DeepSeekAuthStore(
            files: FakeFiles([DeepSeekAuthStore.configPaths[0]: #"{"apiKey":"ds-file"}"#]),
            environment: FakeEnvironment(["DEEPSEEK_API_KEY": "ds-env"])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "ds-file")
    }

    func testFallsBackToEnvironmentWhenNoConfigFile() {
        let store = DeepSeekAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["DEEPSEEK_API_KEY": "ds-env"])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "ds-env")
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["DEEPSEEK_API_KEY": "ds-env"]
        let file = [DeepSeekAuthStore.configPaths[0]: #"{"apiKey":"ds-file"}"#]

        XCTAssertEqual(DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment()).keyStatus(), .notSet)
        XCTAssertEqual(DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(), .fromEnvironment)
        XCTAssertEqual(DeepSeekAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).keyStatus(), .saved)
        XCTAssertEqual(DeepSeekAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(), .overrideActive)
    }

    func testSavedKeyOverridesEnvironment() throws {
        let files = FakeFiles()
        let store = DeepSeekAuthStore(files: files, environment: FakeEnvironment(["DEEPSEEK_API_KEY": "ds-env"]))

        try store.saveAPIKey("  ds-saved  ")

        XCTAssertEqual(files.files[DeepSeekAuthStore.configPaths[0]], #"{"apiKey":"ds-saved"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "ds-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testDeleteAPIKeyFallsBackToEnvironment() throws {
        let files = FakeFiles([DeepSeekAuthStore.configPaths[0]: #"{"apiKey":"ds-file"}"#])
        let store = DeepSeekAuthStore(files: files, environment: FakeEnvironment(["DEEPSEEK_API_KEY": "ds-env"]))

        try store.deleteAPIKey()

        XCTAssertNil(files.files[DeepSeekAuthStore.configPaths[0]])
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "ds-env")
    }

    // MARK: - Declared starting balance

    func testReadsInitialBalanceFromEnvironment() {
        let store = DeepSeekAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["DEEPSEEK_INITIAL_BALANCE": " $1,000.50 "])
        )

        XCTAssertEqual(try XCTUnwrap(store.loadInitialBalance()), 1000.50, accuracy: 0.001)
    }

    func testIgnoresUnusableInitialBalance() {
        // Junk or non-positive values must not turn into a meter with a nonsense ceiling.
        for raw in ["", "lots", "0", "-5"] {
            let store = DeepSeekAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["DEEPSEEK_INITIAL_BALANCE": raw])
            )
            XCTAssertNil(store.loadInitialBalance(), "expected nil for \(raw.debugDescription)")
        }
    }

    func testInitialBalanceIsNilWhenUnset() {
        let store = DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadInitialBalance())
    }
}

// MARK: - DeepSeekUsageMapperTests

final class DeepSeekUsageMapperTests: XCTestCase {
    func testMapsBalanceOnlyWithoutDeclaredStartingBalance() throws {
        let lines = try DeepSeekUsageMapper.lines(from: data(balanceUSDJSON), initialBalance: nil)

        XCTAssertEqual(lines.count, 1)
        let balance = try XCTUnwrap(values(lines, "Balance")?.first)
        XCTAssertEqual(balance.number, 12.5, accuracy: 0.001)
        XCTAssertEqual(balance.kind, .dollars)
        XCTAssertNil(progress(lines, "Credits"))
    }

    func testAddsCreditsMeterAgainstDeclaredStartingBalance() throws {
        let lines = try DeepSeekUsageMapper.lines(from: data(balanceUSDJSON), initialBalance: 20)

        let credits = try XCTUnwrap(progress(lines, "Credits"))
        XCTAssertEqual(credits.used, 7.5, accuracy: 0.001)
        XCTAssertEqual(credits.limit, 20, accuracy: 0.001)
        XCTAssertEqual(credits.format, .dollars)
    }

    func testClampsMeterWhenBalanceExceedsDeclaredStartingBalance() throws {
        // A top-up after the starting balance was declared must read as an empty meter, not a
        // negative one.
        let lines = try DeepSeekUsageMapper.lines(from: data(balanceUSDJSON), initialBalance: 5)

        XCTAssertEqual(try XCTUnwrap(progress(lines, "Credits")).used, 0, accuracy: 0.001)
    }

    func testNonUSDBalanceRendersWithItsCurrencyNotDollars() throws {
        let lines = try DeepSeekUsageMapper.lines(from: data(balanceCNYJSON), initialBalance: 200)

        let balance = try XCTUnwrap(values(lines, "Balance")?.first)
        XCTAssertEqual(balance.kind, .count)
        XCTAssertEqual(balance.label, "CNY")
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Credits")).format, .count(suffix: "CNY"))
    }

    func testPrefersUSDWhenAccountHoldsSeveralCurrencies() {
        XCTAssertEqual(
            DeepSeekUsageMapper.balance(from: data(balanceBothCurrenciesJSON)),
            DeepSeekUsageMapper.Balance(currency: "USD", total: 4)
        )
    }

    func testThrowsOnUnusableBody() {
        // A body with no balance is an invalid response, never a silent zero balance.
        XCTAssertThrowsError(try DeepSeekUsageMapper.lines(from: data(#"{"is_available":true}"#), initialBalance: nil)) { error in
            XCTAssertEqual(error as? DeepSeekUsageError, .invalidResponse)
        }
    }

    func testZeroBalanceIsAMeasuredZero() throws {
        let lines = try DeepSeekUsageMapper.lines(
            from: data(#"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0.00"}]}"#),
            initialBalance: nil
        )

        XCTAssertEqual(try XCTUnwrap(values(lines, "Balance")?.first).number, 0)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, format: ProgressFormat)? {
        guard case .progress(_, let used, let limit, let format, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format)
    }
}

// MARK: - DeepSeekProviderTests

@MainActor
final class DeepSeekProviderTests: XCTestCase {
    func testRefreshMapsBalance() async throws {
        let provider = DeepSeekProvider(
            authStore: makeAuthStore(key: "ds-test"),
            usageClient: DeepSeekUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.url, DeepSeekUsageClient.balanceURL)
                XCTAssertEqual(request.headers["Authorization"], "Bearer ds-test")
                return jsonResponse(balanceUSDJSON)
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Balance"))
        XCTAssertNil(snapshot.line(label: "Credits"))
    }

    func testRefreshAddsCreditsMeterWhenStartingBalanceDeclared() async {
        let provider = DeepSeekProvider(
            authStore: DeepSeekAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment([
                    "DEEPSEEK_API_KEY": "ds-test",
                    "DEEPSEEK_INITIAL_BALANCE": "20"
                ])
            ),
            usageClient: DeepSeekUsageClient(http: RoutingHTTPClient { _ in jsonResponse(balanceUSDJSON) })
        )

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.line(label: "Credits"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = DeepSeekProvider(
            authStore: DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: DeepSeekUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("must not call the API without a key")
                return jsonResponse("{}")
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshReportsInvalidKeyOn401() async {
        let provider = DeepSeekProvider(
            authStore: makeAuthStore(key: "ds-bad"),
            usageClient: DeepSeekUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshReportsNetworkFailure() async {
        let provider = DeepSeekProvider(
            authStore: makeAuthStore(key: "ds-test"),
            usageClient: DeepSeekUsageClient(http: RoutingHTTPClient { _ in
                throw URLError(.notConnectedToInternet)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testHasLocalCredentialsMatchesKeyPresence() async {
        let withKey = DeepSeekProvider(authStore: makeAuthStore(key: "ds-test"))
        let without = DeepSeekProvider(
            authStore: DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        )

        let detected = await withKey.hasLocalCredentials()
        let undetected = await without.hasLocalCredentials()

        XCTAssertTrue(detected)
        XCTAssertFalse(undetected)
    }

    private func makeAuthStore(key: String) -> DeepSeekAuthStore {
        DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment(["DEEPSEEK_API_KEY": key]))
    }
}

private func jsonResponse(_ jsonString: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(jsonString.utf8))
}
