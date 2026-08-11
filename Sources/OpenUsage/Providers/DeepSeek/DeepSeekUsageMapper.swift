import Foundation

/// Builds metric lines from DeepSeek's `/user/balance` payload.
///
/// The API reports what's left, not what was spent, so Balance is the primary row. A meter needs a
/// ceiling the API never sends, so Credits only appears when the user declares a starting balance
/// (`DEEPSEEK_INITIAL_BALANCE`); without it the provider shows the balance alone rather than a meter
/// against a guessed limit.
enum DeepSeekUsageMapper {
    /// One currency's balance as reported by the API. DeepSeek bills in CNY for most accounts and USD
    /// for some, so the currency travels with the number instead of being assumed.
    struct Balance: Equatable {
        var currency: String
        var total: Double
    }

    static func lines(from body: Data, initialBalance: Double?) throws -> [MetricLine] {
        guard let balance = balance(from: body) else {
            throw DeepSeekUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        // Credits: spend against the user-declared starting balance. Clamped so a top-up (balance above
        // the declared start) reads as an empty meter rather than a negative one.
        if let initialBalance, initialBalance > 0 {
            let used = min(max(0, initialBalance - balance.total), initialBalance)
            lines.append(.progress(
                label: "Credits",
                used: used,
                limit: initialBalance,
                format: format(for: balance.currency)
            ))
        }
        // A real zero is shown ("$0.00 left"), never "No data".
        lines.append(.values(label: "Balance", values: [value(balance)]))
        return lines
    }

    /// The balance to show: the USD entry when the account has one, otherwise the first entry the API
    /// listed. A single account can carry several currencies, and only one row is rendered.
    static func balance(from body: Data) -> Balance? {
        guard
            let root = ProviderParse.jsonObject(body),
            let infos = root["balance_infos"] as? [[String: Any]]
        else { return nil }

        let balances: [Balance] = infos.compactMap { info in
            guard let total = ProviderParse.number(info["total_balance"]) else { return nil }
            let currency = (info["currency"] as? String)?.uppercased() ?? "USD"
            return Balance(currency: currency, total: total)
        }
        return balances.first { $0.currency == "USD" } ?? balances.first
    }

    /// USD renders as dollars; any other currency renders as a plain number with its code as the unit,
    /// so a CNY balance never prints a misleading "$".
    private static func value(_ balance: Balance) -> MetricValue {
        balance.currency == "USD"
            ? MetricValue(number: max(0, balance.total), kind: .dollars)
            : MetricValue(number: max(0, balance.total), kind: .count, label: balance.currency)
    }

    private static func format(for currency: String) -> ProgressFormat {
        currency == "USD" ? .dollars : .count(suffix: currency)
    }
}
