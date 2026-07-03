# claude-statusline

A friendly status line for [Claude Code](https://claude.com/claude-code). It shows your model,
context usage, git branch, and reasoning effort, plus color-coded bars for your 5-hour and 7-day
rate limits — and an optional budget bar if your account has pay-as-you-go usage enabled.

```
Sonnet 5 · ctx 42% · on develop ✔ · effort high
5h     ━━──────────  18% resets Fri 23:09
7d     ━━━─────────  22% resets Jul 6, 22:09
budget ━──────────── $10.42 / $100
```

- The model name is bold and colored, so it's the first thing your eye catches on line 1.
- Every bar lines up in a neat column no matter how long its label is.
- Bar color tells you how you're doing: green is fine, yellow means slow down, red means you're
  close to the limit.
- If Claude Code hasn't sent rate-limit numbers yet (this happens briefly at the start of a
  session), the last known reading is shown instead, marked with a `~`. You'll never see stale
  data from a reset window that's already passed.
- The budget line uses real account data, fetched with the same login Claude Code already has —
  no extra setup needed. It's the only network call this script makes, and the result is cached
  so it won't hit the API on every render. It's simply left out if your account doesn't have
  pay-as-you-go usage enabled.

## What you need

- `bash`, `awk`, `jq` (`brew install jq` / `apt-get install jq`), `curl`
- A terminal font with basic Unicode line-drawing support — most monospace fonts already have
  this, no special Nerd/Powerline font required.
- Linux only, and only for the budget bar: `secret-tool` (part of `libsecret-tools`), as a
  fallback if no other login token is found. Not needed on macOS.

## Install it

```bash
git clone https://github.com/nutbutterfly/claude-statusline.git
cd claude-statusline
./install.sh
```

This copies the script to `~/.claude/statusline-command.sh` and adds it to your
`~/.claude/settings.json`, without touching anything else already there. Restart Claude Code (or
start a new session) to see it.

## Make it yours

Everything you'd want to tweak lives in `statusline-command.sh`:

- `BAR_WIDTH` — how wide each bar is (default `12`)
- `BAR_FILLED_CHAR` / `BAR_EMPTY_CHAR` — the filled/empty bar characters (default `━` / `─`)
- `BUDGET_CACHE_TTL` — how often the budget number refreshes, in seconds (default `60`)
- `LABEL_WIDTH` — how much space each label gets (default `6`)
- The green/yellow/red thresholds, in `render_bar()` (default `60` / `85`)
- Colors, near the top of the file (`GREEN`, `YELLOW`, `RED`, `BLUE`, `WHITE`, `DIM`)

## Cache files

- `~/.claude/statusline-cache.json` — your last known rate-limit reading, used briefly at the
  start of a session before fresh numbers arrive.
- `~/.claude/statusline-usage-cache.json` — your last fetched budget data.

Both rebuild themselves automatically, so it's safe to delete either one at any time.

## License

MIT
