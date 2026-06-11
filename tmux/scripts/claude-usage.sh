#!/usr/bin/env bash
# Claude usage badge for the tmux status bar.
#
# Fetches session (5h) + weekly (7d, incl. active per-model) usage from the
# Claude OAuth usage endpoint and prints a tmux-styled one-liner, e.g.:
#   59% 2.0h ┊ 26% 3.7d ┊ 1%
# Gauges are unlabeled and in a fixed order (session, weekly, weekly-opus,
# weekly-sonnet), with each percentage colored by threshold (green <50 · amber
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
fallback() {
    [ -f "$CACHE" ] && cat "$CACHE" || true
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

# jq emits one TSV row per present gauge (utilization non-null), in display order:
#   utilization \t show-countdown \t resets_at
# The active per-model weekly entries share the weekly reset, so they carry
# show-countdown=false (no countdown rendered); session/weekly carry their own.
LINES=$(printf '%s' "$USAGE_JSON" | jq -r '
  [ {key:"five_hour",        cd:"true"},
    {key:"seven_day",        cd:"true"},
    {key:"seven_day_opus",   cd:"false"},
    {key:"seven_day_sonnet", cd:"false"} ][] as $g
  | (.[$g.key] // null) as $e
  | select($e != null and $e.utilization != null)
  | [($e.utilization|tostring), $g.cd, ($e.resets_at // "")] | @tsv
' 2>/dev/null) || fallback

NOW=$(date +%s)
SEP=" #[fg=${CU_SEP}]┊ " # dotted-bar separator between gauges

OUT=""
while IFS=$'\t' read -r util cdflag resets; do
    [ -n "$util" ] || continue
    printf -v p '%.0f' "$util" # round utilization to a whole %
    # load-colored % (+ dim reset countdown when applicable)
    g="#[fg=$(col "$p")]${p}%"
    if [ "$cdflag" = "true" ]; then
        cd=$(countdown "$resets" "$NOW")
        if [ -n "$cd" ]; then g="$g #[fg=${CU_TIME}]${cd}"; fi
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
