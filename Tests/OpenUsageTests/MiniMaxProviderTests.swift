import XCTest
@testable import OpenUsage

// MARK: - Sample payloads
/// Mirrors the `/v1/token_plan/remains` shapes captured in `docs/providers/minimax.md`: counts when
/// the plan provisions them, remaining percentages when it doesn't.

private let remainsCountsJSON = #"""
{
  "model_remains": [
    {
      "model_name": "general",
      "start_time": 1786460400000,
      "end_time": 1786478400000,
      "current_interval_total_count": 1000000,
      "current_interval_usage_count": 250000,
      "weekly_start_time": 1786320000000,
      "weekly_end_time": 1786924800000,
      "current_weekly_total_count": 20000000,
      "current_weekly_usage_count": 5000000
    },
    {
      "model_name": "video",
      "current_interval_total_count": 10,
      "current_interval_usage_count": 10,
      "current_weekly_total_count": 10,
      "current_weekly_usage_count": 10
    }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
"""#

/// The shape a Token Plan reports when it provisions no counts: zeroed counts and a remaining
/// percentage per window (captured from a live Plus account).
private let remainsPercentJSON = #"""
{
  "model_remains": [
    {
      "model_name": "general",
      "start_time": 1786460400000,
      "end_time": 1786478400000,
      "current_interval_total_count": 0,
      "current_interval_usage_count": 0,
      "current_interval_remaining_percent": 13,
      "weekly_start_time": 1786320000000,
      "weekly_end_time": 1786924800000,
      "current_weekly_total_count": 0,
      "current_weekly_usage_count": 0,
      "current_weekly_remaining_percent": 100
    }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
"""#

private let remainsAuthFailureJSON = #"""
{ "base_resp": { "status_code": 1004, "status_msg": "invalid api key" } }
"""#

private func data(_ json: String) -> Data {
    Data(json.utf8)
}

// MARK: - MiniMaxAuthStoreTests

final class MiniMaxAuthStoreTests: XCTestCase {
    func testPrefersConfigFileOverEnvironment() {
        let store = MiniMaxAuthStore(
            files: FakeFiles([MiniMaxAuthStore.configPaths[0]: #"{"apiKey":"mm-file"}"#]),
            environment: FakeEnvironment(["MINIMAX_API_KEY": "mm-env"])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "mm-file")
    }

    func testCodingPlanKeyBeatsGeneralAPIKey() {
        // The quota endpoint only accepts the Token Plan key, so on a machine carrying both it wins.
        let store = MiniMaxAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment([
                "MINIMAX_API_KEY": "mm-payg",
                "MINIMAX_CODE_PLAN_KEY": "mm-plan"
            ])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "mm-plan")
    }

    func testFallsBackToGeneralAPIKey() {
        let store = MiniMaxAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["MINIMAX_API_KEY": "mm-env"])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "mm-env")
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        XCTAssertNil(MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment()).loadAPIKey())
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["MINIMAX_API_KEY": "mm-env"]
        let file = [MiniMaxAuthStore.configPaths[0]: #"{"apiKey":"mm-file"}"#]

        XCTAssertEqual(MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment()).keyStatus(), .notSet)
        XCTAssertEqual(MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(), .fromEnvironment)
        XCTAssertEqual(MiniMaxAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).keyStatus(), .saved)
        XCTAssertEqual(MiniMaxAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(), .overrideActive)
    }

    func testSavedKeyOverridesEnvironment() throws {
        let files = FakeFiles()
        let store = MiniMaxAuthStore(files: files, environment: FakeEnvironment(["MINIMAX_API_KEY": "mm-env"]))

        try store.saveAPIKey(" mm-saved ")

        XCTAssertEqual(files.files[MiniMaxAuthStore.configPaths[0]], #"{"apiKey":"mm-saved"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "mm-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }
}

// MARK: - MiniMaxUsageMapperTests

final class MiniMaxUsageMapperTests: XCTestCase {
    func testMapsCountsToBothMeters() throws {
        let lines = try MiniMaxUsageMapper.map(remainsBody: data(remainsCountsJSON))

        let session = try XCTUnwrap(progress(lines, "Session"))
        XCTAssertEqual(session.used, 25, accuracy: 0.001)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.format, .percent)
        // Window length and reset come from the entry's own boundaries, not a hardcoded cadence.
        XCTAssertEqual(session.periodDurationMs, 5 * 60 * 60 * 1000)
        XCTAssertEqual(try XCTUnwrap(session.resetsAt?.timeIntervalSince1970), 1_786_478_400, accuracy: 0.5)

        let weekly = try XCTUnwrap(progress(lines, "Weekly"))
        XCTAssertEqual(weekly.used, 25, accuracy: 0.001)
        XCTAssertEqual(weekly.periodDurationMs, 7 * 24 * 60 * 60 * 1000)
        XCTAssertEqual(try XCTUnwrap(weekly.resetsAt?.timeIntervalSince1970), 1_786_924_800, accuracy: 0.5)
    }

    func testMetersTheChatPoolNotTheOtherModelPools() throws {
        // `model_remains` carries one entry per pool (chat, video, …). The fully-consumed video pool
        // must not be what the meters read.
        let lines = try MiniMaxUsageMapper.map(remainsBody: data(remainsCountsJSON))

        XCTAssertEqual(try XCTUnwrap(progress(lines, "Session")).used, 25, accuracy: 0.001)
    }

    func testFallsBackToTheFirstPoolWhenNoneIsNamedGeneral() throws {
        let lines = try MiniMaxUsageMapper.map(remainsBody: data(#"""
        {"model_remains":[{"model_name":"text","current_interval_total_count":100,"current_interval_usage_count":60}]}
        """#))

        XCTAssertEqual(try XCTUnwrap(progress(lines, "Session")).used, 60, accuracy: 0.001)
    }

    func testFallsBackToRemainingPercentWhenCountsAreUnprovisioned() throws {
        // Some plans report zeroed counts and only a remaining percentage. MiniMax reports what's
        // left; the meters show what's used.
        let lines = try MiniMaxUsageMapper.map(remainsBody: data(remainsPercentJSON))

        XCTAssertEqual(try XCTUnwrap(progress(lines, "Session")).used, 87, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Weekly")).used, 0, accuracy: 0.001)
    }

    func testReadsQuotaAtTopLevelWhenUnwrapped() throws {
        let lines = try MiniMaxUsageMapper.map(remainsBody: data(#"""
        {"current_weekly_total_count": 100, "current_weekly_usage_count": 40}
        """#))

        XCTAssertNil(progress(lines, "Session"))
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Weekly")).used, 40, accuracy: 0.001)
    }

    func testAcceptsEpochMillisecondResetTimes() throws {
        let lines = try MiniMaxUsageMapper.map(remainsBody: data(#"""
        {"current_interval_remaining_percent": 50, "end_time": 1786478400000}
        """#))

        let resetsAt = try XCTUnwrap(progress(lines, "Session")?.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince1970, 1_786_478_400, accuracy: 0.5)
    }

    func testMissingWindowsYieldNoUsageData() throws {
        // No counts and no percentages: the shared placeholder, not a meter reading zero or full.
        let lines = try MiniMaxUsageMapper.map(remainsBody: data(#"{"data":{}}"#))

        XCTAssertTrue(lines.contains { $0.label == "Status" })
        XCTAssertNil(progress(lines, "Session"))
    }

    func testBusinessLevelFailureThrows() {
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(remainsBody: data(remainsAuthFailureJSON))) { error in
            XCTAssertEqual(error as? MiniMaxUsageError, .apiError(code: 1004, message: "invalid api key"))
        }
        XCTAssertTrue(MiniMaxUsageMapper.isAuthFailure(.apiError(code: 1004, message: "invalid api key")))
    }

    func testNonAuthBusinessCodeIsNotAnAuthFailure() {
        XCTAssertFalse(MiniMaxUsageMapper.isAuthFailure(.apiError(code: 1008, message: "insufficient balance")))
    }

    func testUnparsableBodyThrowsInvalidResponse() {
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(remainsBody: Data("<html>".utf8))) { error in
            XCTAssertEqual(error as? MiniMaxUsageError, .invalidResponse)
        }
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, resetsAt, periodDurationMs)
    }
}

// MARK: - MiniMaxProviderTests

@MainActor
final class MiniMaxProviderTests: XCTestCase {
    func testRefreshMapsBothMeters() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "mm-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.url, MiniMaxUsageClient.remainsURL)
                XCTAssertEqual(request.headers["Authorization"], "Bearer mm-test")
                return jsonResponse(remainsCountsJSON)
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = MiniMaxProvider(
            authStore: MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("must not call the API without a key")
                return jsonResponse("{}")
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshReportsInvalidKeyFromBusinessCodeOn200() async {
        // MiniMax rejects a pay-as-you-go key with a 200 + `base_resp.status_code` 1004, so the auth
        // error has to come out of the body rather than the status line.
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "mm-payg"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in jsonResponse(remainsAuthFailureJSON) })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshReportsInvalidKeyOn401() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "mm-bad"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshReportsNetworkFailure() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "mm-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                throw URLError(.timedOut)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testHasLocalCredentialsMatchesKeyPresence() async {
        let withKey = MiniMaxProvider(authStore: makeAuthStore(key: "mm-test"))
        let without = MiniMaxProvider(
            authStore: MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        )

        let detected = await withKey.hasLocalCredentials()
        let undetected = await without.hasLocalCredentials()

        XCTAssertTrue(detected)
        XCTAssertFalse(undetected)
    }

    private func makeAuthStore(key: String) -> MiniMaxAuthStore {
        MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment(["MINIMAX_API_KEY": key]))
    }
}

private func jsonResponse(_ jsonString: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(jsonString.utf8))
}
