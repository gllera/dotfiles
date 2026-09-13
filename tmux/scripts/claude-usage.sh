#!/usr/bin/env bash
# Claude usage badge for the tmux status bar.
#
# Prints a tmux-styled one-liner: the Claude Code spend rate (last 15 min, $/h), then session
# (5h) + weekly (7d, incl. per-model) usage from the Claude OAuth usage endpoint, the session and
# weekly percentages between what their window has spent so far and its time left, e.g.:
#   $26/h ┊ $31 16% 3.5h ┊ $151 80% 5.3d ┊ 43% Fable
# Gauges render in the API's order (session, weekly, then one per active model);
# session and weekly show a reset countdown, per-model gauges are labeled with
# the model name. Each percentage is colored by threshold (green <50 · amber
# 50-80 · red >80); all other text is dim. Bash + jq, like its siblings here.
#
# Spend comes from claude-spend (`claude-spend usage`: every session on every host, priced
# from the transcripts; source in ~/tempo/statusline). Without claude-spend the badge shows the
# limits alone.
#
# The API response is cached for $TTL seconds as data, not markup, and the pill is
# drawn from it on every redraw: the status bar redraws every status-interval (15s)
# but the network is hit ~once/min, while countdowns and spend stay live. The OAuth
# token is read fresh from the credentials file on every fetch — Claude Code rotates
# it, we never refresh it ourselves. Any failure (expired token / offline / parse
# error) keeps the last cached limits, or shows the spend alone if there are none,
# so the status bar never shows an error.

set -euo pipefail

# Badge palette lives in config.sh; everything else is set here.
HERE="${0%/*}"
. "$HERE/config.sh"

# OAuth token file written by Claude Code, in its config dir (~/.config/claude here).
CRED="${CLAUDE_CONFIG_DIR:-$HOME/.config/claude}/.credentials.json"
CS="${CLAUDE_SPEND_BIN:-claude-spend}"
# The cache: a header line (last fetch attempt), then one line per limit, in the
# API's order:
#   percent ␟ kind ␟ reset epoch (0: none) ␟ model label
# Fields are joined with \x1f (unit separator), NOT a tab: most rows carry an empty
# field, and a tab is IFS-whitespace, so `read` would collapse empty fields and
# shift the rest; \x1f is not, so they survive the split.
CACHE="${TMPDIR:-/tmp}/claude-usage.$EUID.limits"
TTL=60 # seconds to cache a response before refetching
NOW=$EPOCHSECONDS
US=$'\x1f'
DIM="#[fg=${CU_TIME}]"
SEP=" #[fg=${CU_SEP}]┊ " # dotted-bar separator between gauges

# The cached limits, read forklessly (the common path touches no network).
C_AT=0 L=()
if [ -f "$CACHE" ]; then
    {
        IFS=$US read -r C_AT || true
        while IFS= read -r x; do if [ -n "$x" ]; then L+=("$x"); fi; done
    } <"$CACHE"
fi
[[ $C_AT =~ ^[0-9]+$ ]] || C_AT=0

# spend: from claude-spend, for the logged-in account, S5 and S7, what the session and
# weekly windows have spent, SQ, the last 15 min, and E5 and E7, the windows' resets.
# Nano-dollars and epochs; zero and empty when claude-spend is missing or fails.
spend() {
    S5=0 S7=0 SQ=0 E5="" E7=""
    command -v "$CS" >/dev/null 2>&1 || return 0
    eval "$("$CS" usage --account current 2>/dev/null | jq -r '
      def nano: if type == "number" then . * 1e9 | round else 0 end;
      @sh "S5=\(.five_hour.usd | nano) S7=\(.seven_day.usd | nano) SQ=\(.rate.usd_per_hour | nano / 4 | floor)",
      @sh "E5=\(.five_hour.resets_at // "") E7=\(.seven_day.resets_at // "")"' 2>/dev/null)" || true
}

# tenths VALUE DIVISOR VAR: VALUE / DIVISOR to one decimal, "d.d". Pure integer math
# (bash has no floats): scale by 10 and add half the divisor so the divide rounds
# rather than truncates, then split the tenths into integer/fraction.
tenths() {
    local t=$((($1 * 10 + $2 / 2) / $2))
    printf -v "$3" '%d.%d' $((t / 10)) $((t % 10))
}
# usd NANO VAR: whole dollars and a space, empty under $0.50.
usd() {
    if (($1 >= 500000000)); then printf -v "$2" '%s$%d ' "$DIM" $((($1 + 500000000) / 1000000000))
    else printf -v "$2" ''; fi
}
# rate NANO VAR: 15 minutes' spend as $/h, a decimal under $10/h and whole dollars
# above, empty under $0.10/h (like the status line's own rate).
rate() {
    local c=$(($1 * 4 / 10000000)) d # cents per hour
    if ((c >= 995)); then printf -v "$2" '%s$%d/h' "$DIM" $(((c + 50) / 100))
    elif ((c >= 10)); then tenths "$c" 100 d; printf -v "$2" '%s$%s/h' "$DIM" "$d"
    else printf -v "$2" ''; fi
}
# countdown EPOCH VAR: time to reset, largest unit only: days/hours to 1 decimal,
# minutes whole (floored).
countdown() {
    local s=$(($1 - NOW)) d
    if ((s < 0)); then s=0; fi
    if ((s >= 86400)); then tenths "$s" 86400 d; printf -v "$2" '%sd' "$d"
    elif ((s >= 3600)); then tenths "$s" 3600 d; printf -v "$2" '%sh' "$d"
    else printf -v "$2" '%dm' $((s / 60)); fi
}
# draw: the pill from the limits and the spend: the rate, then each gauge — the
# session and weekly ones led by their window's spend, per-model ones carrying their
# label, the others their countdown. bg set once; the #[fg=...] changes leave it
# intact. No trailing space/gap: the pill abuts the gold session block that follows
# it in status-right (see tmux.conf), so #[default] resets right at its edge.
draw() {
    local x p k r l g c cd d5 d7 out
    usd "$S5" d5; usd "$S7" d7; rate "$SQ" out
    for x in "${L[@]}"; do
        IFS=$US read -r p k r l <<<"$x"
        # the session and weekly gauges show claude-spend's own reset
        case $k in
            session) if [[ $E5 =~ ^[0-9]+$ ]]; then r=$E5; fi ;;
            weekly_all) if [[ $E7 =~ ^[0-9]+$ ]]; then r=$E7; fi ;;
        esac
        if ((p >= CU_RED_AT)); then c=$CU_RED
        elif ((p >= CU_AMBER_AT)); then c=$CU_AMBER
        else c=$CU_GREEN; fi
        g="#[fg=$c]$p%"
        case $k in
            weekly_scoped) if [ -n "$l" ]; then g="$g $DIM$l"; fi ;;
            session) g="$d5$g" ;;&
            weekly_all) g="$d7$g" ;;&
            *) if ((r > 0)); then countdown "$r" cd; g="$g $DIM$cd"; fi ;;
        esac
        out+="${out:+$SEP}$g"
    done
    if [ -n "$out" ]; then printf '%s' "#[bg=${CU_PILL}] ${out} #[default]"; fi
}

# save: rewrite the cache from C_AT and L, through a temp file per process (tmux
# runs this once per attached client, so writes can overlap).
save() {
    {
        printf '%s\n' "$C_AT"
        if ((${#L[@]})); then printf '%s\n' "${L[@]}"; fi
    } 2>/dev/null >"$CACHE.tmp.$$" && mv -f "$CACHE.tmp.$$" "$CACHE" 2>/dev/null || true
}

# fetch: refresh L from the usage endpoint; non-zero on any failure, L untouched.
# CU_FAKE_USAGE is a test seam: when set, it stands in for the response, so the
# render path can be exercised without the network (and without a token).
fetch() {
    local json=${CU_FAKE_USAGE:-} token rows
    command -v jq >/dev/null 2>&1 || return 1
    if [ -z "$json" ]; then
        command -v curl >/dev/null 2>&1 && [ -r "$CRED" ] || return 1
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED" 2>/dev/null) && [ -n "$token" ] || return 1
        json=$(curl -fsS --max-time 5 \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "anthropic-version: 2023-06-01" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1
    fi
    # `limits` holds one entry per limit: an integer `percent`, a `kind` (session /
    # weekly_all / weekly_scoped), its `resets_at` (ISO 8601; made an epoch here,
    # fractional seconds and any ±HH:MM offset handled, 0 if absent or unreadable)
    # and, for scoped entries (which share the weekly reset), the model in
    # `scope.model.display_name`.
    rows=$(jq -r --arg us "$US" '
      def epoch: (try (capture("^(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")
          | (.t + "Z" | fromdateiso8601)
            - ((.z // "Z") as $z | if $z == "Z" then 0
               else ($z[1:3] | tonumber) * 3600 + ($z[-2:] | tonumber) * 60 | if $z[0:1] == "-" then -. else . end end))
        catch empty) // 0;
      .limits[]? | select(.percent != null)
      | [ (.percent | round), (.kind // ""), ((.resets_at // "") | epoch), (.scope.model.display_name // "") ]
      | map(tostring) | join($us)' <<<"$json" 2>/dev/null) || return 1
    [ -n "$rows" ] || return 1
    mapfile -t L <<<"$rows"
}

# Fresh limits: draw with the live spend and bail (the common path).
if ((NOW - C_AT < TTL)); then
    spend
    draw
    exit 0
fi

# Stale or missing: claim the fetch first by stamping the cache with this attempt
# (limits unchanged), so other tmux clients redrawing meanwhile draw from it instead
# of fetching too, and a *failed* fetch still counts against the TTL: failures back
# off to one retry per TTL, the same cadence as success, instead of every 15s redraw
# re-hitting a 429ing endpoint and never letting the rate limit clear.
C_AT=$NOW
save

# Then, fetched or not, draw from the new limits or the last ones.
fetch || true
save
spend
draw
