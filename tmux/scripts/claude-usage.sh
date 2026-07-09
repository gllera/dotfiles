#!/usr/bin/env bash
# Claude usage badge for the tmux status bar.
#
# Fetches session (5h) + weekly (7d, incl. per-model) usage from the Claude
# OAuth usage endpoint and prints a tmux-styled one-liner, e.g.:
#   41% 2.0h ┊ 28% 13h ┊ 43% Fable
# Gauges render in the API's order (session, weekly, then one per active model);
# session and weekly show a reset countdown, per-model gauges are labeled with
# the model name. Each percentage is colored by threshold (green <50 · amber
# 50-80 · red >80).
#
# Pure bash: jq parses the JSON, GNU/uutils `date -d` does the reset countdowns.
# This keeps the whole scripts/ directory single-language (its siblings —
# claude-tmux.sh, pane-switch.sh — are bash too); python3 was the lone outlier.
#
# Result is cached for $TTL seconds: the status bar redraws every
# status-interval (15s) but the network is hit ~once/min. The OAuth token is
# read fresh from the credentials file on every fetch — Claude Code rotates it,
# we never refresh it ourselves. Any failure (expired token / offline / parse
# error) falls back to the last cached value, or prints nothing if there is none,
# so the status bar never shows an error.

set -euo pipefail

# Badge palette lives in config.sh; everything else is set here.
HERE="${0%/*}"
. "$HERE/config.sh"

# Credentials file written by Claude Code, holding the OAuth access token. Lives
# in CLAUDE_CONFIG_DIR, which defaults to ~/.config/claude here (this config has
# been relocated there from Claude Code's own ~/.claude default).
CRED="${CLAUDE_CONFIG_DIR:-$HOME/.config/claude}/.credentials.json"
CACHE="${TMPDIR:-/tmp}/claude-usage.$EUID.cache"
TTL=60 # seconds to cache a response before refetching

# Fresh cache wins — read it and bail (the common path, no network). Fires on every
# status redraw, so the read is forkless ($(<file), not a cat subprocess).
if [ -f "$CACHE" ]; then
    age=$(($(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0)))
    if [ "$age" -lt "$TTL" ]; then
        printf '%s' "$(<"$CACHE")"
        exit 0
    fi
fi

# Last-known value on any failure; nothing if we've never succeeded.
# touch bumps the cache mtime so a *failed* fetch still counts against the TTL
# gate above: without it, mtime stays pinned to the last success, age is always
# >= TTL, and every 15s redraw re-hits the network — hammering a 429ing endpoint
# 4x/min and never letting the rate limit clear. With it, failures back off to
# one retry per TTL, the same cadence as success.
fallback() {
    if [ -f "$CACHE" ]; then
        touch "$CACHE"
        cat "$CACHE"
    fi
    exit 0
}

command -v jq >/dev/null 2>&1 || fallback

# USAGE_JSON is the raw usage response. CU_FAKE_USAGE is a test seam: when set,
# it stands in for the response so the render path can be exercised without the
# network (and without a token). Empty/unset -> real fetch.
USAGE_JSON="${CU_FAKE_USAGE:-}"
if [ -z "$USAGE_JSON" ]; then
    command -v curl >/dev/null 2>&1 || fallback
    [ -r "$CRED" ] || fallback
    TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED" 2>/dev/null) || fallback
    [ -n "$TOKEN" ] || fallback
    USAGE_JSON=$(curl -fsS --max-time 5 \
        -H "Authorization: Bearer $TOKEN" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "anthropic-version: 2023-06-01" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || fallback
fi

# Percentage color by load.
col() {
    if [ "$1" -ge "$CU_RED_AT" ]; then
        printf '%s' "$CU_RED"
    elif [ "$1" -ge "$CU_AMBER_AT" ]; then
        printf '%s' "$CU_AMBER"
    else
        printf '%s' "$CU_GREEN"
    fi
}

# Time-to-reset, largest unit only: days/hours to 1 decimal, minutes whole.
# Pure integer math (bash has no floats): scale by 10 and add half the divisor
# so the divide rounds (matching python's :.1f) rather than truncates; minutes
# floor, as before. Then split the tenths into integer/fraction.
countdown() {
    local resets=$1 now=$2 target secs t
    [ -n "$resets" ] || return 0
    target=$(date -d "$resets" +%s 2>/dev/null) || return 0
    secs=$((target - now))
    if ((secs < 0)); then secs=0; fi
    if ((secs >= 86400)); then
        t=$(((secs * 10 + 43200) / 86400))
        printf '%d.%dd' $((t / 10)) $((t % 10))
    elif ((secs >= 3600)); then
        t=$(((secs * 10 + 1800) / 3600))
        printf '%d.%dh' $((t / 10)) $((t % 10))
    else
        printf '%dm' $((secs / 60))
    fi
}

# The usage API moved per-model breakdowns out of the old fixed seven_day_opus/
# seven_day_sonnet keys (now always null) and into the `limits` array: one entry
# per limit, each with an integer `percent`, a `kind` (session / weekly_all /
# weekly_scoped), its own `resets_at`, and — for scoped entries — the model in
# `scope.model.display_name`. jq emits one \x1f-joined row per limit, in array
# order, with four fields:
#   percent ␟ show-countdown ␟ resets_at ␟ label
# weekly_scoped entries share the weekly reset (no countdown) but carry the model
# name as a label; session and weekly_all render their own countdown, no label.
#
# Fields are joined with \x1f (unit separator), NOT a tab: scoped rows have an
# empty resets_at and session/weekly rows have an empty label, so most rows carry
# an empty *middle* field. A tab is IFS-whitespace, so `read` would collapse the
# empty field and shift every column after it (dropping the label). \x1f is
# non-whitespace, so empty fields survive the split.
LINES=$(printf '%s' "$USAGE_JSON" | jq -r '
  .limits[]?
  | select(.percent != null)
  | [ (.percent|tostring),
      (if .kind == "weekly_scoped" then "false" else "true" end),
      (.resets_at // ""),
      (.scope.model.display_name // "") ] | join("\u001f")
' 2>/dev/null) || fallback

NOW=$(date +%s)
SEP=" #[fg=${CU_SEP}]┊ " # dotted-bar separator between gauges

OUT=""
while IFS=$'\x1f' read -r pct cdflag resets label; do
    [ -n "$pct" ] || continue
    printf -v p '%.0f' "$pct" # percent is already whole; round defensively
    # load-colored % (+ dim reset countdown, or dim model label on per-model rows)
    g="#[fg=$(col "$p")]${p}%"
    if [ "$cdflag" = "true" ]; then
        cd=$(countdown "$resets" "$NOW")
        if [ -n "$cd" ]; then g="$g #[fg=${CU_TIME}]${cd}"; fi
    elif [ -n "$label" ]; then
        g="$g #[fg=${CU_TIME}]${label}"
    fi
    if [ -n "$OUT" ]; then OUT="$OUT$SEP"; fi
    OUT="$OUT$g"
done <<<"$LINES"

[ -n "$OUT" ] || fallback

# bg set once; the #[fg=...] changes leave it intact through the whole pill.
# No trailing space/gap: the pill abuts the gold session block that follows it
# in status-right (see tmux.conf), so #[default] resets right at the pill edge.
OUT="#[bg=${CU_PILL}] ${OUT} #[default]"

printf '%s' "$OUT" >"$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
printf '%s' "$OUT"
