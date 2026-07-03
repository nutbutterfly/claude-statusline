#!/bin/bash
# Claude Code statusLine
# Layout built entirely from the statusLine stdin JSON payload:
#   Line 1: model, context usage, git branch (clean/dirty), reasoning effort
#   Line 2: session (5-hour) rate-limit usage, with its reset countdown
#   Line 3: weekly (7-day) rate-limit usage, with its reset countdown
#   Line 4 (optional): extra-usage spend vs your account's monthly limit,
#           fetched from Anthropic's usage API; shown only when the account
#           has extra/pay-as-you-go usage enabled

input=$(cat)
# Prefer workspace.current_dir (documented field); fall back to top-level cwd
# for robustness in case a future/older payload variant omits it.
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')

# --- Data pulled from the statusLine stdin payload ---
model_name=$(echo "$input" | jq -r '.model.display_name // empty')
ctx_used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
effort_level=$(echo "$input" | jq -r '.effort.level // empty')
session_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
session_reset_epoch=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
weekly_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
weekly_reset_epoch=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

now_epoch=$(date +%s)

# Column width every meter label (5h/7d/budget) pads to, so their bars all
# start at the same position regardless of label length.
LABEL_WIDTH=6

# --- Rate-limit cache ---
# rate_limits is absent from the payload until the first API response of the
# session, so a fresh session shows "n/a" for a bit even though the last
# known usage is still roughly valid. Cache the last live reading globally
# (usage is account-wide, not per-project) and fall back to it — but only
# while its reset time is still in the future, since a value from an
# already-elapsed window is wrong, not just stale.
CACHE_FILE="$HOME/.claude/statusline-cache.json"
session_is_cached=0
weekly_is_cached=0

if [ -f "$CACHE_FILE" ]; then
  if [ -z "$session_pct" ]; then
    c_pct=$(jq -r '.session_pct // empty' "$CACHE_FILE" 2>/dev/null)
    c_reset=$(jq -r '.session_reset_epoch // empty' "$CACHE_FILE" 2>/dev/null)
    if [ -n "$c_pct" ] && [ -n "$c_reset" ] && [ "$c_reset" -gt "$now_epoch" ] 2>/dev/null; then
      session_pct="$c_pct"
      session_reset_epoch="$c_reset"
      session_is_cached=1
    fi
  fi
  if [ -z "$weekly_pct" ]; then
    c_pct=$(jq -r '.weekly_pct // empty' "$CACHE_FILE" 2>/dev/null)
    c_reset=$(jq -r '.weekly_reset_epoch // empty' "$CACHE_FILE" 2>/dev/null)
    if [ -n "$c_pct" ] && [ -n "$c_reset" ] && [ "$c_reset" -gt "$now_epoch" ] 2>/dev/null; then
      weekly_pct="$c_pct"
      weekly_reset_epoch="$c_reset"
      weekly_is_cached=1
    fi
  fi
fi

# Persist the effective (live-or-still-valid-cache) reading so the next
# session start has something to fall back on. Written atomically so a
# concurrent statusLine render never sees a half-written file.
tmp_cache=$(mktemp "${CACHE_FILE}.XXXXXX" 2>/dev/null)
if [ -n "$tmp_cache" ] && jq -n \
  --argjson sp "${session_pct:-null}" \
  --argjson sr "${session_reset_epoch:-null}" \
  --argjson wp "${weekly_pct:-null}" \
  --argjson wr "${weekly_reset_epoch:-null}" \
  '{session_pct: $sp, session_reset_epoch: $sr, weekly_pct: $wp, weekly_reset_epoch: $wr}' \
  > "$tmp_cache" 2>/dev/null; then
  mv "$tmp_cache" "$CACHE_FILE"
else
  rm -f "$tmp_cache" 2>/dev/null
fi

# --- Budget (extra usage) data ---
# Unlike the rate limits above, extra-usage/pay-as-you-go credit data isn't in
# the statusLine payload at all — it's account billing data, only available
# via Anthropic's authenticated usage API (the same one Claude Code itself
# uses). Cached separately from statusline-cache.json (a raw API response on
# a flat mtime TTL, not a payload-derived percentage keyed off a reset time)
# with a short TTL so the frequently-invoked statusline doesn't hit the API
# on every render.
BUDGET_CACHE_FILE="$HOME/.claude/statusline-usage-cache.json"
BUDGET_CACHE_TTL=60

usage_data=""
usage_cache_fresh=0
if [ -f "$BUDGET_CACHE_FILE" ]; then
  cache_mtime=$(stat -c %Y "$BUDGET_CACHE_FILE" 2>/dev/null || stat -f %m "$BUDGET_CACHE_FILE" 2>/dev/null)
  if [ -n "$cache_mtime" ] && [ $((now_epoch - cache_mtime)) -lt "$BUDGET_CACHE_TTL" ] 2>/dev/null; then
    usage_cache_fresh=1
  fi
  usage_data=$(cat "$BUDGET_CACHE_FILE" 2>/dev/null)
fi

if [ "$usage_cache_fresh" -eq 0 ]; then
  # Look for the OAuth token Claude Code already stores locally, in the same
  # order/places it does, stopping at the first one found. No token means no
  # network call is attempted at all.
  token="$CLAUDE_CODE_OAUTH_TOKEN"
  if [ -z "$token" ] && command -v security >/dev/null 2>&1; then
    blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    [ -n "$blob" ] && token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  fi
  if [ -z "$token" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
  fi
  if [ -z "$token" ] && command -v secret-tool >/dev/null 2>&1; then
    blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
    [ -n "$blob" ] && token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  fi

  if [ -n "$token" ]; then
    response=$(curl -s --max-time 5 \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    if [ -n "$response" ] && echo "$response" | jq -e '.extra_usage' >/dev/null 2>&1; then
      usage_data="$response"
      tmp_usage=$(mktemp "${BUDGET_CACHE_FILE}.XXXXXX" 2>/dev/null)
      if [ -n "$tmp_usage" ]; then
        echo "$response" > "$tmp_usage" && mv "$tmp_usage" "$BUDGET_CACHE_FILE"
      else
        rm -f "$tmp_usage" 2>/dev/null
      fi
    fi
  fi
  # On any failure above (no token, curl error, bad response), $usage_data is
  # left as whatever was already read from the cache file, stale or not —
  # a slightly old number beats none, and this only ever affects line 4.
fi

# extra_usage.is_enabled reflects whether the account has pay-as-you-go usage
# turned on at all; used_credits/monthly_limit are in cents.
budget_enabled="false"
budget_spent=""
budget_limit=""
if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
  budget_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
  if [ "$budget_enabled" = "true" ]; then
    budget_spent=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
    budget_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
  fi
fi

# Colors
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[1;34m'
WHITE='\033[37m'
DIM='\033[2m'
RESET='\033[0m'
MODEL_COLOR='\033[1;35m'

# Git branch for cwd, with a dirty/clean marker
git_info=""
if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  if [ -n "$branch" ]; then
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
      dirty_marker="${RED}\xe2\x9c\x98${RESET}"
    else
      dirty_marker="${GREEN}\xe2\x9c\x94${RESET}"
    fi
    git_info="${YELLOW}on${RESET} ${WHITE}${branch} ${dirty_marker}"
  fi
fi

# format_reset(): unix epoch -> local date/time ("Thu 18:00"; adds the date
# too once the reset is more than a day out, since the 7-day window needs it)
# (blank if missing/invalid)
format_reset() {
  epoch="$1"
  case "$epoch" in
    ''|null) return ;;
  esac
  diff=$(( epoch - now_epoch ))
  if [ "$diff" -le 0 ]; then
    echo "now"
    return
  fi
  if [ "$diff" -ge 86400 ]; then
    date -r "$epoch" "+%b %-d, %H:%M"
  else
    date -r "$epoch" "+%a %H:%M"
  fi
}

# render_bar(pct): builds a fixed-width progress bar into the globals
# $bar_str (colored bar) and $meter_color (matching color, reused for the
# percentage text next to it). Empty/non-numeric pct renders an all-empty
# dim bar, since width should stay constant even in the "n/a" state.
# Uses thin rule characters (heavy/light horizontal, not full-height blocks):
# a solid block glyph fills its entire cell height, so when two stacked meter
# lines both have a column filled, the blocks touch top-to-bottom and read as
# one connected shape spanning both lines. A thin rule sits near the vertical
# center of the cell with visible background above and below, so adjacent
# rows stay visually distinct even when their filled columns overlap.
BAR_WIDTH=12
BAR_FILLED_CHAR='━'
BAR_EMPTY_CHAR='─'
render_bar() {
  p="$1"
  case "$p" in
    ''|*[!0-9.]*)
      filled=0
      meter_color="$DIM"
      ;;
    *)
      filled=$(awk -v p="$p" -v w="$BAR_WIDTH" 'BEGIN{n=int(p*w/100+0.5); if(n<0)n=0; if(n>w)n=w; print n}')
      level=$(awk -v p="$p" 'BEGIN{ if (p>=85) print "red"; else if (p>=60) print "yellow"; else print "green" }')
      case "$level" in
        red) meter_color="$RED" ;;
        yellow) meter_color="$YELLOW" ;;
        *) meter_color="$GREEN" ;;
      esac
      ;;
  esac
  empty=$((BAR_WIDTH - filled))
  filled_str=$(printf '%*s' "$filled" '' | tr ' ' "$BAR_FILLED_CHAR")
  empty_str=$(printf '%*s' "$empty" '' | tr ' ' "$BAR_EMPTY_CHAR")
  bar_str="${meter_color}${filled_str}${DIM}${empty_str}${RESET}"
}

# render_meter(label, pct, reset_epoch, is_cached): builds
# "<label> [bar] <pct>% resets <countdown>" (or "... n/a") into the global
# $meter_part. Shared by the 5h and 7d meters so they can't drift apart. The
# label is padded to LABEL_WIDTH and shown in one neutral color so every
# meter's bar starts at the same column — severity color lives on the bar
# fill and value text only, not the label.
render_meter() {
  label=$(printf '%-*s' "$LABEL_WIDTH" "$1")
  pct="$2"
  reset_epoch="$3"
  is_cached="$4"
  render_bar "$pct"
  if [ -n "$pct" ]; then
    reset=$(format_reset "$reset_epoch")
    prefix=""
    [ "$is_cached" -eq 1 ] && prefix="~"
    pct_str=$(printf '%s%.0f%%' "$prefix" "$pct")
    meter_part="${WHITE}${label}${RESET} ${bar_str} ${meter_color}$(printf '%-4s' "$pct_str")${RESET}"
    [ -n "$reset" ] && meter_part="${meter_part}  ${DIM}resets ${reset}${RESET}"
  else
    meter_part="${WHITE}${label}${RESET} ${bar_str} ${DIM}n/a${RESET}"
  fi
}

# --- Line 1: model, context usage, git branch, reasoning effort ---
# Segments are joined with the same soft dot divider used on line 2.
divider=" ${DIM}\xc2\xb7${RESET} "
line1=""
add_segment() {
  [ -z "$1" ] && return
  if [ -z "$line1" ]; then
    line1="$1"
  else
    line1="${line1}${divider}$1"
  fi
}
[ -n "$model_name" ] && add_segment "${MODEL_COLOR}${model_name}${RESET}"
[ -n "$ctx_used" ] && add_segment "${BLUE}ctx${RESET} $(printf '%.0f' "$ctx_used")%"
add_segment "$git_info"
[ -n "$effort_level" ] && add_segment "${YELLOW}effort${RESET} ${effort_level}"

# --- Line 2: session (5h) rate-limit usage ---
# --- Line 3: weekly (7d) rate-limit usage ---
# Bar fill color signals severity (green/yellow/red by usage level); a "~"
# before the percentage marks a reading served from cache (pre-dates this
# session's first API response) rather than the live payload.
render_meter "5h" "$session_pct" "$session_reset_epoch" "$session_is_cached"
line2="$meter_part"

render_meter "7d" "$weekly_pct" "$weekly_reset_epoch" "$weekly_is_cached"
line3="$meter_part"

# --- Line 4 (optional): extra-usage spend vs the account's monthly limit ---
# Only shown when the account actually has extra/pay-as-you-go usage enabled
# — same "no data, no segment" rule as line 1, gated on real account state
# rather than "have we ever seen a cost figure".
line4=""
if [ "$budget_enabled" = "true" ] && [ -n "$budget_limit" ]; then
  budget_pct=$(awk -v s="$budget_spent" -v m="$budget_limit" 'BEGIN{ print (m > 0) ? s*100/m : 0 }')
  render_bar "$budget_pct"
  budget_label=$(printf '%-*s' "$LABEL_WIDTH" 'budget')
  max_str=$(printf '%.0f' "$budget_limit")
  line4="${WHITE}${budget_label}${RESET} ${bar_str} ${meter_color}\$${budget_spent}${RESET} ${DIM}/ \$${max_str}${RESET}"
fi

# Note: %b (not %s) is used because line1-4 carry embedded \033[...m escape
# sequences that %b will interpret.
if [ -n "$line4" ]; then
  printf "%b\n%b\n%b\n%b" "$line1" "$line2" "$line3" "$line4"
else
  printf "%b\n%b\n%b" "$line1" "$line2" "$line3"
fi
