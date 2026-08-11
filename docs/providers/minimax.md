# MiniMax

Tracks [MiniMax](https://platform.minimax.io) Token Plan (coding plan) quota usage.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage (percentage), with its reset time |
| Weekly | Weekly window usage (percentage), with its reset time |

## Where credentials come from

MiniMax has no companion CLI/app that OpenUsage can reuse a credential from, so you supply an API
key. OpenUsage reads it from the first place it finds one, in this order:

1. `~/.config/openusage/minimax.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. `~/.config/minimax/key.json`
3. The `MINIMAX_CODE_PLAN_KEY` environment variable
4. The `MINIMAX_CODING_API_KEY` environment variable
5. The `MINIMAX_API_KEY` environment variable

The coding-plan names are checked first because the quota endpoint only answers to the **Token Plan**
key — on a machine that exports both, that's the one OpenUsage needs. You can also add and rotate the
key from **Settings → API Keys** without touching a file.

## Setup

1. Subscribe to a [Token Plan](https://platform.minimax.io/docs/token-plan/intro) and copy its key
   from the MiniMax console (Account → Token Plan). A pay-as-you-go API key will not work here.
2. Add it to OpenUsage via **Settings → API Keys**, **or** export it:

```bash
export MINIMAX_CODE_PLAN_KEY="YOUR_TOKEN_PLAN_KEY"
```

3. MiniMax appears on the dashboard on the next refresh.

## Under the hood

One call: `GET https://api.minimax.io/v1/token_plan/remains`, with your key as a bearer token.
MiniMax also runs a mainland-China host (`api.minimaxi.com`) with the same path; OpenUsage targets the
global host only.

The response carries a `model_remains` list with one entry per model pool (`general` for chat and
coding, `video`, and so on). OpenUsage meters the chat pool and ignores the rest, since that's what a
coding agent spends.

Within that entry, token counts (`current_interval_total_count` / `current_interval_usage_count` and
the weekly pair) drive the meters when the plan provisions them; plans that leave those at zero report
a remaining percentage instead, which OpenUsage inverts — MiniMax reports what's left, the meters show
what's used. A window with neither reads "No data" rather than an empty or full bar. Each window's
length and reset come from its own `start_time` / `end_time` boundaries (epoch milliseconds, seconds,
or an ISO-8601 string), so the pace line follows your plan instead of an assumed cadence.

MiniMax reports most failures as a code inside the response body on an HTTP 200; code `1004` (a
rejected or wrong-type key) is surfaced as an authentication error, and any other code is shown with
its message.

## Troubleshooting

- **"No MiniMax API key"** — add a key in Settings → API Keys, or export `MINIMAX_CODE_PLAN_KEY`.
- **"MiniMax key rejected…"** — the key was refused. This usually means a pay-as-you-go API key was
  used; the quota endpoint needs the Token Plan key.
- **Meters show "No usage data"** — the key worked but the plan reported no quota for either window.
  This happens on plans where the quota isn't provisioned yet; check the usage bar in the
  [MiniMax console](https://platform.minimax.io).
- **Session reads 100% while Weekly reads 0%** — that's what MiniMax reported: the chat pool's
  5-hour window is out of quota (`current_interval_remaining_percent` is 0) while the weekly window
  is untouched. The Session meter clears at the reset time shown on the row.
