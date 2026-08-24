# Ollama

Tracks [Ollama Cloud](https://ollama.com) subscription usage — the session and weekly limits Ollama
shows on its own settings page.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour window usage (percentage of your plan's allowance) |
| Weekly | 7-day window usage (percentage of your plan's allowance) |
| Last 4 Weeks | Recent activity spend. $0.00 on a subscription; real amounts for pay-as-you-go and API-key usage |

Your plan (Free, Pro, Max) is shown beside the provider name.

Session and Weekly are always visible and start pinned to the menu bar. Last 4 Weeks sits behind the
provider's caret — you can move any of them in **Customize**.

The session window is 5 hours and the weekly window is 7 days, but Ollama reports only how much of each
window you have used — never when the current one started or ends. These meters therefore show no reset
countdown, rather than a guessed one. Local models don't count toward either limit; only cloud models do.

## Where credentials come from

Nothing to paste. Ollama creates a signing key at `~/.ollama/id_ed25519` the first time it runs, and
`ollama signin` links that key to your ollama.com account. OpenUsage reads the key, signs each request
with it exactly as the Ollama CLI does, and never sends the key anywhere — only the signature goes out.

Because the key exists whether or not you've signed in, OpenUsage can only tell that Ollama is
installed, not that Ollama Cloud is set up. If a first launch turns Ollama on for a local-only install,
the card explains that you aren't signed in; turn it off in **Customize** if you don't use the cloud.

## Setup

1. Install [Ollama](https://ollama.com/download) and subscribe to a [cloud plan](https://ollama.com/pricing).
2. Sign in:

```bash
ollama signin
```

3. Ollama appears on the dashboard on the next refresh, with Session and Weekly in the menu bar.

## Under the hood

Two ollama.com endpoints, both authenticated with a signature from your local Ollama key:

- `GET https://ollama.com/api/usage` — the session and weekly meters plus recent activity spend.
- `POST https://ollama.com/api/me` — the plan name (best-effort; a failure here doesn't blank the meters).

Each request carries an `Authorization` header of `<public key>:<signature>`, signing the string
`<METHOD>,<request-uri>` where the URI includes a `ts` unix-seconds parameter — the same scheme the
Ollama CLI uses, so a captured header can't be replayed later.

The usage endpoint is undocumented (it backs Ollama's own settings page), so OpenUsage reads it
defensively: `usage` is a fraction (`0.349` → 34.9%) and `cost` is a decimal string; a limit that isn't
in the response is left off the dashboard rather than shown as zero usage. A response with no `limits`
at all is reported as an invalid response.

## Troubleshooting

- **"No Ollama key found"** — Ollama has never run on this Mac. [Install it](https://ollama.com/download)
  and run `ollama signin`.
- **"Not signed in to Ollama Cloud"** — Ollama is installed but the key isn't linked to an account.
  Run `ollama signin`.
- **"Couldn't read ~/.ollama/id_ed25519"** — the key file exists but isn't readable. Check its
  permissions (it should be owned by you, mode `600`).
- **Meters show "No usage data"** — you're signed in, but Ollama returned no limits for the account yet.
  Check your usage at [ollama.com/settings](https://ollama.com/settings).
