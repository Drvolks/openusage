# DeepSeek

Tracks the balance left on your [DeepSeek](https://platform.deepseek.com) platform account.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Optional meter: how much of a starting balance you've spent (see below) |
| Balance | Money left on the account (granted + topped-up), in the account's own currency |

DeepSeek's platform API reports only what's left — it has no spend history, quota, or plan endpoint —
so Balance is the whole picture unless you tell OpenUsage what you started with.

## Where credentials come from

DeepSeek has no companion CLI/app that OpenUsage can reuse a credential from, so you supply an API
key. OpenUsage reads it from the first place it finds one, in this order:

1. `~/.config/openusage/deepseek.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. `~/.config/deepseek/key.json`
3. The `DEEPSEEK_API_KEY` environment variable
4. The `DEEPSEEK_TOKEN` environment variable

You can also add and rotate the key from **Settings → API Keys** without touching a file.

## Setup

1. Create a key in the [DeepSeek console](https://platform.deepseek.com/api_keys).
2. Add it to OpenUsage via **Settings → API Keys**, **or** export it:

```bash
export DEEPSEEK_API_KEY="YOUR_API_KEY"
```

3. DeepSeek appears on the dashboard on the next refresh.

### Showing a percentage (optional)

A meter needs a ceiling, and DeepSeek never sends one. Declare what your balance started at and the
**Credits** row turns into a meter — "$7.50 of $20.00 starting balance":

```bash
export DEEPSEEK_INITIAL_BALANCE="20"
```

Use the same currency your account is billed in. The value is read from the environment only (the
config file is rewritten whenever Settings saves a key, so a value parked there would be lost), and
it's yours to update after a top-up.

Credits is the row shown on the card; Balance sits in the **On Demand** section behind the card's
caret. Without the starting balance set, the Credits row reads "No data" — expand the card for
Balance, or swap the two in Customize.

## Under the hood

One call: `GET https://api.deepseek.com/user/balance`, with your key as a bearer token.

The response lists a balance per currency. OpenUsage shows the USD entry when the account has one and
otherwise the first entry, rendering a non-USD balance with its currency code ("110 CNY") rather than
a misleading dollar sign. A zero balance is shown as a real zero, never as "No data".

## Troubleshooting

- **"No DeepSeek API key"** — add a key in Settings → API Keys, or export `DEEPSEEK_API_KEY`.
- **"DeepSeek API key invalid"** — the key was rejected (401/403). Regenerate it in the
  [DeepSeek console](https://platform.deepseek.com/api_keys).
- **Credits reads "No data"** — `DEEPSEEK_INITIAL_BALANCE` isn't set (or isn't a positive number).
  Balance still works without it.
