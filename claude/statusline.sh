#!/usr/bin/env bash
# Claude Code status line
# Reads the session JSON on stdin and prints one left-aligned row, fitted to $COLUMNS (wrapped here):
#   <model> <effort>  <dir> <branch>* ↑<ahead>↓<behind> ⎇ <worktree>  ━━━━──── <tok>K
#   … [<min>m][/<ttl>] <n>✗ <cause>  (or cold)  $<cost>  $<rate>/h  $<per 1M>/M  ████████  #<pr>
# Nothing is padded: Claude Code doesn't re-run the script on a resize, so a shrink cuts the
# row's end until the next refresh (refreshInterval: 5 s).
# Segments are omitted when empty/zero. Git state is computed locally (cached briefly).
# After a compaction (PostCompact hook in settings.json) the cost, miss count and the bar's window
# restart: they cover only what accrued since it.
# After the cost: the spend rate over the last 15 min ($/h), then the 8-cell bar splitting the
# spend on the last ~5M tokens, subagents included, by colour in 64ths (eighth blocks): green
# cache read, yellow cache write, red output (+ uncached input), gray other; $/M before it is their
# cost per 1M tokens. Each refresh that prices spend logs it with the plan's usage-limit %
# (usage-<host>.log, in $CLAUDE_USAGE_LOG_DIR or cache/statusline).

cache_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/statusline"
# usage log, one file per host so a folder synced between machines never has two writers on one
# file; the analysis merges them by time. Set CLAUDE_USAGE_LOG_DIR in the environment Claude Code
# starts with (a shell rc, or settings.json "env"), not only in the statusLine command, so the
# PostCompact hook, which trims the log, sees it too.
host=${HOSTNAME%%.*}; host=${host//[^A-Za-z0-9_-]/}
ul_dir=${CLAUDE_USAGE_LOG_DIR:-$cache_dir}; ul="$ul_dir/usage-${host:-host}.log"

# PostCompact hook mode (`statusline.sh --compacted`): empty the session's base3-<sid> file, which
# makes the next render snapshot the baseline (see "compaction baseline"), prune week-old cache
# files (usage logs excepted), and trim this host's usage log past 8 MB to its header and last 8
# days (the tmux badge's weekly spend reads 7; a symlinked log is trimmed at its target).
# Silent and always exits 0, so it never surfaces as a hook error.
if [ "${1:-}" = --compacted ]; then
  sid=$(jq -r '.session_id // empty' 2>/dev/null); sid=${sid//[^A-Za-z0-9_-]/}
  if [ -n "$sid" ]; then
    mkdir -p "$cache_dir" 2>/dev/null && : > "$cache_dir/base3-$sid" 2>/dev/null
    find "$cache_dir" -type f -mtime +7 ! -name 'usage*.log*' -delete 2>/dev/null
    [ -L "$ul" ] && ul=$(readlink -f "$ul")
    [ -n "$(find "$ul" -size +8M 2>/dev/null)" ] \
      && { head -n 1 "$ul"; awk -F'\t' -v c=$(( $(date +%s) - 691200 )) 'NR > 1 && $1 >= c' "$ul"; } \
         > "$ul.tmp.$$" 2>/dev/null && mv -f "$ul.tmp.$$" "$ul"
  fi
  exit 0
fi

now=$EPOCHSECONDS
[ -d "$cache_dir" ] || mkdir -p "$cache_dir" 2>/dev/null

# --- colors: quiet by default, colour only when something needs attention ---
# Identity hues are fixed and never a signal (dir, branch, worktree); metrics stay default or
# dim while healthy. Signals use tmux's 256-colour codes so they match the Claude state markers
# on the pane borders: WARN 220 (attention), ALERT 196 (act now), GOOD 40 (PR approved only).
RESET=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; GRAY=$'\033[90m'
DIRC=$'\033[34m'; BRANCH=$'\033[95m'; WTC=$'\033[2;95m'
WARN=$'\033[38;5;220m'; ALERT=$'\033[38;5;196m'; GOOD=$'\033[38;5;40m'

# --- fields: one jq pass over stdin, emitting shell-quoted (@sh) assignments that are eval'd ---
# Named, so adding a field needs no renumbering. Booleans and null print bare (true/false/null),
# arrays and objects empty (@sh would print an array as several words, which eval would run);
# bad JSON prints nothing, leaving every field unset (defaults below). No apostrophes in this
# program: it sits inside single quotes. `exec` spares the subshell a fork.
eval "$(exec jq -r '
  def ttl: startswith("ttl_expired");                          # idle-TTL expiry miss causes
  def num: if type == "number" then floor else null end;       # integer, else null
  def n: num // 0;                                             # counts: integer, else 0
  def short: {system_prompt_changed: "sysprompt", likely_server_side: "server"}[.]
             // (sub("_changed$"; "") | gsub("_"; "-"));        # miss cause → short label
  def v: if type == "array" or type == "object" then "" else . end;   # scalars only
  .context_window as $w | (.prompt_cache // {}) as $p |
  @sh "model=\(.model.display_name // "Claude" | v) mid=\(.model.id // "" | v) fast=\(.fast_mode | v)",
  @sh "effort=\(.effort.level // "" | v) cwd=\(.cwd // .workspace.current_dir // "" | v)",
  @sh "wt=\(.workspace.git_worktree // .worktree.name // "" | v) sid=\(.session_id // "" | v) tp=\(.transcript_path // "" | v)",
  @sh "cost=\(.cost.total_cost_usd // 0 | v) pr_num=\(.pr.number // "" | v) pr_state=\(.pr.review_state // "" | v)",
  @sh "ctx=\($w.used_percentage // "" | v) tok=\($w.total_input_tokens | n)",
  # plan usage limits (subscriptions only): used % and reset epoch, for the usage log
  @sh "rl5=\(.rate_limits.five_hour.used_percentage // "" | v) rl5r=\(.rate_limits.five_hour.resets_at // "" | v)",
  @sh "rl7=\(.rate_limits.seven_day.used_percentage // "" | v) rl7r=\(.rate_limits.seven_day.resets_at // "" | v)",
  @sh "pc_seen=\($p.caching_observed | v) pc_warm=\($p.warm | v) pc_ttl=\($p.ttl // "" | v) pc_exp=\($p.expires_at | num // "")",
  # misses and the last miss cause, minus idle-TTL expiries (the cold state already shows those);
  # the cause label gets a "+" when there were several
  @sh "pc_miss=\(try ([($p.misses | n) - ([($p.miss_causes // {}) | to_entries[] | select(.key | ttl) | .value | n] | add // 0), 0] | max) catch 0)",
  @sh "pc_cause=\(try (($p.last_miss_cause.causes // []) | map(strings | select(ttl | not)) | if length == 0 then "" else (.[0] | short) + (if length > 1 then "+" else "" end) end) catch "")"
' 2>/dev/null)"
: "${model:=Claude}"
sid=${sid//[^A-Za-z0-9_-]/}
for v in tok pc_miss; do [[ ${!v} =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
model=${model% (*context)}   # "Opus 5 (1M context)" → "Opus 5"
dir=${cwd##*/}; [ "$cwd" = "$HOME" ] && dir="~"                # the cwd's last component

# \x1f-separated cache records (tab is IFS whitespace, so `read` would collapse empty middle fields)
# put writes a temp file and renames it over, so an overlapping render never reads it half-written;
# unchanged content (most refreshes) isn't rewritten, sparing the mv
put() { local f=$1 IFS=$'\x1f' o; shift; { IFS= read -r o < "$f"; } 2>/dev/null; [ "$o" = "$*" ] && return
        printf '%s\n' "$*" 2>/dev/null > "$f.$$" && mv -f "$f.$$" "$f" 2>/dev/null; }
get() { local _f=$1; shift; [ -f "$_f" ] && IFS=$'\x1f' read -r "$@" < "$_f"; }

# --- git branch + dirty + ahead/behind (cached 3 s per cwd to stay snappy in big repos) ---
# One `status --porcelain=v2 --branch` call: `# branch.*` headers carry head/oid/ab, any other
# line is a change. --no-optional-locks keeps refreshes off index.lock so they can't collide with
# a concurrent git command. The record starts with its own timestamp, so no stat is needed.
branch=""; dirty=""; ahead=""; behind=""
if [ -n "$cwd" ]; then
  cf="$cache_dir/gitv3-${cwd//\//%}"; ts=""
  get "$cf" ts branch dirty ahead behind
  if ! [[ $ts =~ ^[0-9]+$ ]] || [ $(( now - ts )) -ge 3 ]; then
    branch=""; dirty=""; ahead=""; behind=""
    if st=$(git --no-optional-locks -C "$cwd" status --porcelain=v2 --branch 2>/dev/null); then
      oid=""
      while IFS= read -r l; do
        case "$l" in
          '# branch.oid '*)  oid=${l#'# branch.oid '} ;;
          '# branch.head '*) branch=${l#'# branch.head '} ;;
          '# branch.ab '*)   read -r _ _ ahead behind <<<"$l"; ahead=${ahead#+}; behind=${behind#-} ;;
          '#'*|'') ;;
          *) dirty="*" ;;
        esac
      done <<<"$st"
      [ "$branch" = "(detached)" ] && branch=${oid:0:7}
    fi
    put "$cf" "$now" "$branch" "$dirty" "$ahead" "$behind"
  fi
fi

# --- integers: fixed-point money, since bash has no floats ---
# fx turns a decimal string into an integer scaled by 10^digits (10# stops "0970…" reading as
# octal); cfmt prints cents as d.dd, usd 1/10000 $ as d.dd.
fx() { local v; printf -v v "%.${2}f" "${1:-0}" 2>/dev/null || v=0; v=${v/./}; printf -v "$3" '%s' $(( 10#$v )); }
cfmt() { printf -v "$2" '%d.%02d' $(( $1 / 100 )) $(( $1 % 100 )); }
usd() { cfmt $(( ($1 + 50) / 100 )) "$2"; }
clamp() { printf -v "$1" '%s' $(( $2 < $3 ? $3 : $2 > $4 ? $4 : $2 )); }   # VAR value lo hi

# --- compaction baseline: cost and misses restart at a compaction ---
# The PostCompact hook empties base3-<sid>; the next render snapshots the cumulative cost (in
# 1/10000 $) and misses into it, and both then show current − baseline; no baseline reads as
# zeros, i.e. the whole session. A baseline above the cost is ignored, and dropped once the
# window confirms the cost reset (/clear, or a resume resetting it): a single render with older
# JSON must not lose it.
fx "$cost" 4 cur
# state lock: renders can overlap, and the one that doesn't get the lock (flock -n, released on
# exit) only reads the state below. Without flock there's no lock.
lk=1
if [ -n "$sid" ] && command -v flock >/dev/null; then lk=""; exec 9>"$cache_dir/lock-$sid" && flock -n 9 && lk=1; fi 2>/dev/null
base=""; b_raw=""
if [ -n "$sid" ]; then
  bf="$cache_dir/base3-$sid"
  [ -n "$lk" ] && [ -f "$bf" ] && [ ! -s "$bf" ] && put "$bf" "$cur" "$pc_miss"
  get "$bf" b_cost b_miss
  [[ $b_cost =~ ^[0-9]+$ ]] && { b_raw=$b_cost; [ "$b_cost" -le "$cur" ] && base=1; }
fi
[ -n "$base" ] || { b_cost=""; b_miss=""; }
s_cost=$(( cur - b_cost ))                                    # empty reads as 0
s_miss=$(( pc_miss > b_miss ? pc_miss - b_miss : 0 ))

# --- spend window: the bar after the cost, and $/M ---
# Prices are nano-dollars per token (= $/MTok × 1000). State in delta4-<sid>: the cost seen at
# the last refresh, the window's split (read, write, output + input, other), tokens, baseline
# stamp and priced tokens, and whether the last refresh saw the cost drop.
# The window (for the bar and $/M) is a token-weighted moving sum, so it needs no history: each
# response of k tokens first scales the running split and token counts by T / (T + k), then adds
# its own. T = 5M tokens, so it holds about the last 5M tokens (a token's weight halves after
# ~3.5M more: ~11 requests at 300K context). Responses come from the session's transcripts, the
# main one and its subagents' (<transcript>/subagents/*.jsonl), each priced exactly from its own
# usage, model, speed and cache TTL. Only new bytes are read: tx-<sid> keeps each file's offset
# and last response id (a response spans several lines, all with the same usage), and a file not
# modified since the last read began (txm-<sid>'s mtime) isn't opened, so an idle refresh starts
# no process. A new session starts at the files' ends. The cost rise no transcript explains
# (Claude Code's side calls, a model missing from the price table) is "other", converted to
# tokens at the window's own $/token (the cache-read price while empty); with no readable
# transcript at all (a changed format?) the whole bar goes gray and $/M goes.
# $/M is the priced part's cost per U = 1M tokens (a $/MTok rate, comparable to the price sheet):
# priced spend × U / priced tokens, both exact, so "other" never moves it. Until 5M tokens have
# passed the window just holds fewer. $/M is hidden (the bar isn't) until the window holds 500K
# priced tokens: the first request after a compaction re-writes the whole context, and alone it
# reads ~$20 per 1M. Also for a model missing from the price table, whose spend is all "other".
# Money is in micro-dollars, so T × parts can't overflow. It restarts with the cost (/clear,
# resume) and at a compaction: it's stamped with the baseline's cost and emptied, after adding
# that render's increase (like the cost, the compaction's own spend isn't in it), whenever the
# baseline differs from its stamp, so a render that overlapped the snapshot can't carry the old
# window over. A cost drop only counts as a restart when two refreshes in a row see it: a single
# one may be a render whose (older) JSON landed after a newer one's, and leaves the state as is.
# rates MODEL: nano-dollars per input and output token (r_in empty: not in the table), read =
# input / r_rd, r_fast when the model has a fast mode (×2)
rates() { r_in=""; r_rd=10; r_fast=""
  case "$1" in
    claude-opus-5*|claude-opus-4-8*)       r_in=5000;  r_out=25000; r_fast=1 ;;
    claude-opus-4-7*|claude-opus-4-6*)     r_in=5000;  r_out=25000 ;;
    claude-sonnet-5*)                      r_in=2000;  r_out=10000 ;;
    claude-sonnet-4-6*|claude-sonnet-4-5*) r_in=3000;  r_out=15000 ;;
    claude-haiku-4-5*)                     r_in=1000;  r_out=5000 ;;
    claude-fable-5-1*|claude-mythos-5-1*)  r_in=10000; r_out=50000; r_rd=40 ;;
    claude-fable-5*|claude-mythos-5*)      r_in=10000; r_out=50000 ;;
  esac; }
rates "$mid"; p_r=${r_in:+$(( r_in / r_rd ))}                 # the session model's cache-read price
tol=5000                                                     # float noise in the reported total
wT=5000000                                                    # the bar's window, in tokens
wU=1000000                                                    # $/M's unit: cost per this many tokens
# wadd READ WRITE OUT OTHER K Q: the window takes a response (nano-dollars; K tokens, Q of them
# priced): decay by T / (T + K), then add (nano → micro $)
wadd() { local dd=$(( wT + $5 ))
  wr=$(( (wr * wT + dd / 2) / dd + ($1 + 500) / 1000 )); ww=$(( (ww * wT + dd / 2) / dd + ($2 + 500) / 1000 ))
  wo=$(( (wo * wT + dd / 2) / dd + ($3 + 500) / 1000 )); wx=$(( (wx * wT + dd / 2) / dd + ($4 + 500) / 1000 ))
  wk=$(( (wk * wT + dd / 2) / dd + $5 )); wq=$(( (wq * wT + dd / 2) / dd + $6 )); }
# wkx NANO: kx = tokens for unpriced spend, at the window's $/token (the cache-read price if empty)
wkx() { local ws=$(( wr + ww + wo + wx ))
  if [ "$ws" -gt 0 ] && [ "$wk" -gt 0 ]; then kx=$(( $1 / 1000 * wk / ws )); else kx=$(( $1 / ${p_r:-1000} )); fi; }
# transcript chunks → \x1f-separated rows (a missing speed must not shift the fields, as tabs
# would): one per new response (R model speed in write-1h write-5m read out) and per file (F path
# offset last-id). Each chunk is framed by \x1d<path>\x1f<offset>\x1f<id> and \x1e,
# which JSON text can't hold raw; a last line still being written ends glued to the \x1e and isn't
# consumed. Offsets count the UTF-8 bytes of complete lines. A line that doesn't parse as expected
# is skipped (try), so one odd line can't stall the reading; token counts that aren't numbers
# read as 0.
txjq='def i: if type == "number" then floor else 0 end;
  reduce inputs as $l ({o: [], f: null, n: 0, id: ""};
  if ($l | startswith("\u001d")) then ($l[1:] | split("\u001f")) as $h
    | .f = $h[0] | .n = ($h[1] | tonumber) | .id = ($h[2] // "")
  elif ($l | endswith("\u001e")) then .o += [["F", .f, .n, .id]]
  else .n += ($l | utf8bytelength) + 1
    | if ($l | contains("\"usage\"")) then . as $s | try (
        ($l | fromjson) as $j | $j.message as $m | $m.usage as $u
        | if $j.type == "assistant" and ($u | type) == "object" and ($m.id // "") != .id then
            .id = ($m.id // "")
            | .o += [["R", ($m.model // ""), ($u.speed // ""), ($u.input_tokens | i),
                ($u.cache_creation.ephemeral_1h_input_tokens
                  // (($u.cache_creation_input_tokens | i) - ($u.cache_creation.ephemeral_5m_input_tokens | i)) | i),
                ($u.cache_creation.ephemeral_5m_input_tokens | i),
                ($u.cache_read_input_tokens | i), ($u.output_tokens | i)]]
          else . end) catch $s
      else . end
  end) | .o[] | map(tostring) | join("\u001f")'
stale=""; wz=""; rph=0; lg_r=0; lg_w=0; lg_o=0; lg_i=0; lg_x=0 # lg_*: this refresh's spend, for the log
if [ -n "$sid" ]; then
  fx "$cost" 9 cn
  df="$cache_dir/delta4-$sid"; p_cost=""
  get "$df" p_cost wr ww wo wx wk wb wq dn
  for v in wr ww wo wx wk wq; do [[ ${!v} =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
  # transcripts, which feed the window (see above). tx-<sid>: priced, attributed and
  # pending-unexplained spend and when its minute began, then a line per file: path, offset, last
  # response id
  tf="$cache_dir/tx-$sid"; tm="$cache_dir/txm-$sid"; tP=""; tA=""; tU=0; tUt=""
  declare -A toff=() tid=()
  [ -f "$tf" ] && { IFS=$'\x1f' read -r tP tA tU tUt _
                    while IFS=$'\x1f' read -r x1 x2 x3; do toff[$x1]=$x2; tid[$x1]=$x3; done; } < "$tf"
  [[ $tU =~ ^-?[0-9]+$ ]] || tU=0; [[ $tUt =~ ^[0-9]+$ ]] || tUt=""
  if ! [[ $p_cost =~ ^[0-9]+$ ]] || { [ "$cn" -lt "$p_cost" ] && [ -n "$dn" ]; }; then
    dn=""; wz=1; wr=0; ww=0; wo=0; wx=0; wk=0; wq=0           # first refresh, or a cost reset (/clear)
    [ -n "$lk" ] && [ -n "$b_raw" ] && [ "$b_raw" -gt "$cur" ] && rm -f "$bf"   # a baseline above it
  elif [ "$cn" -lt "$p_cost" ]; then
    stale=1; dn=1                                             # a drop seen once: maybe older JSON, late
  else dn=""
  fi
  [ -n "$lk" ] || stale=1                                     # another render holds the lock: read only
  # window from the transcripts (see above)
  if [ -z "$stale" ]; then
    tfs=()                                                    # the files that exist
    if [ -n "$tp" ]; then shopt -s nullglob; tfs=( "${tp%.jsonl}/subagents/"*.jsonl ); shopt -u nullglob
      [ -f "$tp" ] && tfs=( "$tp" "${tfs[@]}" ); fi
    tch=""; t_f=1000000                                       # how much this render's responses age the window (ppm)
    if ! [[ $tP =~ ^[0-9]+$ && $tA =~ ^-?[0-9]+$ ]]; then      # new: start at the files' ends
      [ "${#tfs[@]}" -gt 0 ] && while read -r x1 x2; do toff[$x2]=$x1; done < <(stat -c '%s %n' -- "${tfs[@]}" 2>/dev/null)
      tP=0; tA=$cn; tU=0; tUt=""; tch=1; : > "$tm"
    else
      # not older than the marker: a write in the same clock tick as the last touch has an equal
      # mtime, and must still be read (-nt would miss it until the file changed again)
      chg=(); for x1 in "${tfs[@]}"; do { [ -z "${toff[$x1]+x}" ] || ! [ "$x1" -ot "$tm" ]; } && chg+=( "$x1" ); done
      if [ "${#chg[@]}" -gt 0 ]; then
        : > "$tm"; tch=1                                      # before reading: a write from now is newer
        while IFS=$'\x1f' read -r rk rm rs ri rw1 rw5 rrd ro; do
          if [ "$rk" = F ]; then toff[$rm]=$rs; tid[$rm]=$ri; continue; fi
          rates "$rm"; [ -n "$r_in" ] || continue             # unpriced model: left to "other"
          [ "$rs" = fast ] && [ -n "$r_fast" ] && { r_in=$(( r_in * 2 )); r_out=$(( r_out * 2 )); }
          t_r=$(( rrd * r_in / r_rd )); t_w=$(( rw1 * r_in * 2 + rw5 * r_in * 5 / 4 )); t_o=$(( ro * r_out + ri * r_in ))
          t_k=$(( ri + rw1 + rw5 + rrd + ro )); tP=$(( tP + t_r + t_w + t_o ))
          wadd "$t_r" "$t_w" "$t_o" 0 "$t_k" "$t_k"
          lg_r=$(( lg_r + t_r )); lg_w=$(( lg_w + t_w )); lg_o=$(( lg_o + ro * r_out )); lg_i=$(( lg_i + ri * r_in ))
          t_f=$(( t_f * wT / (wT + t_k) ))
        done < <(for x1 in "${chg[@]}"; do printf '\x1d%s\x1f%s\x1f%s\n' "$x1" "${toff[$x1]:-0}" "${tid[$x1]}"
                   tail -c +$(( ${toff[$x1]:-0} + 1 )) -- "$x1" 2>/dev/null; printf '\x1e\n'; done | jq -nRr "$txjq" 2>/dev/null)
      fi
    fi
    # the cost rise no transcript explains goes to "other" once it has stayed unexplained a
    # minute: the cost lands as soon as a response ends, but its transcript line can take seconds,
    # and renders come as little as 1 s apart. tU is what was pending when that minute began
    # (tUt); spend that arrived since waits for the next minute. Lines that turn up later still
    # make the priced total pass the cost: that much comes back out of "other" (negative other in
    # the log; out of the window aged as those responses aged it), so no spend counts twice.
    # Under $0.001 either way is left alone.
    t_u=$(( cn - tP - tA ))
    if [ -n "$wz" ]; then tA=$(( cn - tP )); tU=0; tUt=""; tch=1   # the window restarted: nothing owed
    elif [ "$t_u" -lt -1000000 ]; then                               # priced past the cost: take it back
      ws=$(( wr + ww + wo + wx )); t_a=$(( -t_u / 1000 * t_f / 1000000 )); [ "$t_a" -gt "$wx" ] && t_a=$wx
      [ "$t_a" -gt 0 ] && { wk=$(( wk - t_a * wk / ws )); [ "$wk" -lt "$wq" ] && wk=$wq; wx=$(( wx - t_a )); }
      lg_x=$t_u; tA=$(( cn - tP )); tU=0; tUt=""; tch=1
    elif [ "$t_u" -le 1000000 ]; then [ "$tU$tUt" != 0 ] && { tU=0; tUt=""; tch=1; }   # nothing pending
    elif [ -z "$tUt" ]; then tU=$t_u; tUt=$now; tch=1                # a minute starts
    elif [ $(( now - tUt )) -ge 60 ]; then
      t_a=$(( t_u < tU ? t_u : tU )); wkx "$t_a"; wadd 0 0 0 "$t_a" "$kx" 0; lg_x=$t_a; tA=$(( tA + t_a ))
      t_u=$(( t_u - t_a )); if [ "$t_u" -gt 1000000 ]; then tU=$t_u; tUt=$now; else tU=0; tUt=""; fi; tch=1
    fi
    if [ -n "$tch" ]; then
      { printf '%s\x1f%s\x1f%s\x1f%s\n' "$tP" "$tA" "$tU" "$tUt"
        for x1 in "${!toff[@]}"; do [ -f "$x1" ] && printf '%s\x1f%s\x1f%s\n' "$x1" "${toff[$x1]}" "${tid[$x1]}"; done
      } 2>/dev/null > "$tf.$$" && mv -f "$tf.$$" "$tf" 2>/dev/null
    fi
  fi
  if [ -z "$lk" ]; then :                                     # read only
  elif [ -n "$stale" ]; then                                  # keep the state, noting the drop
    put "$df" "$p_cost" "$wr" "$ww" "$wo" "$wx" "$wk" "$wb" "$wq" "$dn"
  else
    [ "$wb" != "$b_cost" ] && { wr=0; ww=0; wo=0; wx=0; wk=0; wq=0; wb=$b_cost; }   # new baseline: restart
    put "$df" "$cn" "$wr" "$ww" "$wo" "$wx" "$wk" "$wb" "$wq" "$dn"
  fi
  # spend rate: $/h over the last 15 min, from the session cost (so subagents and Claude Code's
  # side calls count). rate-<sid> keeps a sample (time, cost) at most once a minute, back to the
  # newest one at least 15 min old: the base (else the oldest there is). The time divided by is
  # at least 15 min, so a fresh session ramps up instead of spiking, and the rate fades out 15
  # min after the last spend. It restarts with the cost (/clear); a read-only render only reads.
  rf="$cache_dir/rate-$sid"; rs_t=(); rs_c=(); rch=""
  if [ -n "$wz" ]; then rch=1
  elif [ -f "$rf" ]; then while IFS=$'\x1f' read -r x1 x2; do
      [[ $x1 =~ ^[0-9]+$ && $x2 =~ ^[0-9]+$ ]] && { rs_t+=( "$x1" ); rs_c+=( "$x2" ); }; done < "$rf"; fi
  x1=0; for (( i = 1; i < ${#rs_t[@]}; i++ )); do [ $(( now - rs_t[i] )) -ge 900 ] && x1=$i; done
  [ "$x1" -gt 0 ] && { rs_t=( "${rs_t[@]:x1}" ); rs_c=( "${rs_c[@]:x1}" ); rch=1; }   # older than the base
  if [ -z "$stale" ] && { [ "${#rs_t[@]}" -eq 0 ] || [ $(( now - rs_t[-1] )) -ge 60 ]; }; then
    rs_t+=( "$now" ); rs_c+=( "$cn" ); rch=1; fi
  [ "${#rs_t[@]}" -gt 0 ] && [ "$cn" -gt "${rs_c[0]}" ] \
    && rph=$(( (cn - rs_c[0]) * 36 / ((now - rs_t[0] < 900 ? 900 : now - rs_t[0]) * 100000) ))   # nano-$ → cents/h
  if [ -n "$rch" ] && [ -z "$stale" ]; then
    { for (( i = 0; i < ${#rs_t[@]}; i++ )); do printf '%s\x1f%s\n' "${rs_t[i]}" "${rs_c[i]}"; done
    } 2>/dev/null > "$rf.$$" && mv -f "$rf.$$" "$rf" 2>/dev/null
  fi
  # usage log: a line per refresh that priced spend (transcript responses, subagents included, and
  # "other"), with the plan's usage-limit % at that moment, to fit how much each part weighs on
  # the 5-hour / weekly limits (Anthropic doesn't document it). Tab-separated, money in
  # nano-dollars, output and uncached input apart (they may weigh differently); the limit
  # columns are empty when the JSON carries no rate limits. "Other" taken back (its transcript
  # line came late) is logged as negative other. The tmux badge (claude-usage.sh) sums it for
  # the $/h and the 5-hour / weekly spend, reading columns 1 (ts) and 7 (delta) by position:
  # add new columns at the end. The header is appended, never truncating.
  lg=$(( lg_r + lg_w + lg_o + lg_i + lg_x ))
  if [ $(( lg_r | lg_w | lg_o | lg_i | lg_x )) -ne 0 ]; then
    [ -f "$ul" ] || { mkdir -p "$ul_dir" 2>/dev/null; printf '#ts\tsid\tmodel\tfast\tttl\tcost\tdelta\tread\twrite\tout\tin\tother\tpct5h\treset5h\tpct7d\treset7d\n' 2>/dev/null >> "$ul"; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$sid" "$mid" "$fast" "$pc_ttl" \
      "$cn" "$lg" "$lg_r" "$lg_w" "$lg_o" "$lg_i" "$lg_x" "$rl5" "$rl5r" "$rl7" "$rl7r" 2>/dev/null >> "$ul"
  fi
fi

# bar8 VAR READ WRITE OUT OTHER: the 8-cell bar of a split, in 64ths. Green and red are softer
# than GOOD/ALERT, whose meanings are reserved; yellow is WARN's. Zero parts are dropped, the rest
# get 64ths by largest remainder. A cell shows at most two parts, so a cell edge must sit between
# any two boundaries inside cells: each boundary moves the least that needs, capped (U, from the
# right) so the parts after it still fit, and every part keeps at least 1/64. A cell holding a
# boundary draws its left part as the partial block's foreground and the next as its background,
# so edges stay sharp.
bar8() {
  local out=$1 F=( '38;5;71' '38;5;220' '38;5;167' 90 ) B=( '48;5;71' '48;5;220' '48;5;167' 100 )
  local eighth=( '' ▏ ▎ ▍ ▌ ▋ ▊ ▉ ) v=() fg=() bg=() n=() r=() U=()
  local i=0 t=0 used=0 u=64 x=0 prev=0 s="" m k b lo c p e
  shift
  for x in "$@"; do
    [ "$x" -gt 0 ] && { v+=( "$x" ); fg+=( "${F[i]}" ); bg+=( "${B[i]}" ); t=$(( t + x )); }
    i=$(( i + 1 ))
  done
  m=$(( ${#v[@]} - 1 )); [ "$m" -ge 0 ] || return
  for (( k = 0; k <= m; k++ )); do n[k]=$(( v[k] * 64 / t )); r[k]=$(( v[k] * 64 % t )); used=$(( used + n[k] )); done
  while [ "$used" -lt 64 ]; do
    b=0; for (( k = 1; k <= m; k++ )); do [ "${r[k]}" -gt "${r[b]}" ] && b=$k; done
    n[b]=$(( n[b] + 1 )); r[b]=-1; used=$(( used + 1 ))
  done
  for (( k = m - 1; k >= 0; k-- )); do u=$(( u - 1 < u / 8 * 8 ? u - 1 : u / 8 * 8 )); U[k]=$u; done
  x=0
  for (( k = 0; k < m; k++ )); do
    x=$(( x + n[k] )); lo=$(( prev + 1 > (prev + 7) / 8 * 8 ? prev + 1 : (prev + 7) / 8 * 8 ))
    clamp b "$x" "$lo" "${U[k]}"; n[k]=$(( b - prev )); prev=$b
  done
  n[m]=$(( 64 - prev ))
  p=0; e=${n[0]}                                              # part p covers the cell start, ends at e
  for c in 0 1 2 3 4 5 6 7; do
    lo=$(( c * 8 ))
    while [ "$e" -le "$lo" ]; do p=$(( p + 1 )); e=$(( e + n[p] )); done
    if [ "$e" -ge $(( lo + 8 )) ]; then s+=$'\033[0;'"${fg[p]}m█"
    else s+=$'\033[0;'"${fg[p]};${bg[p+1]}m${eighth[e - lo]}"; fi
  done
  printf -v "$out" '%s' "$s$RESET"
}
dbrk=""; dmin=""                                              # "$<per 1M>/M <bar>" and plain "$<per 1M>/M"
if [ "${wk:-0}" -gt 0 ]; then
  bar=""; bar8 bar "$wr" "$ww" "$wo" "$wx"
  if [ "${wq:-0}" -ge $(( wT / 10 )) ]; then                    # $/M needs 500K priced tokens
    ec=$(( ((wr + ww + wo) * wU / wq + 5000) / 10000 ))         # priced micro-$ per wU priced tokens → cents
    [ "$ec" -gt 0 ] && { cfmt "$ec" dmin; dmin="${DIM}\$${dmin}/M${RESET}"; }   # $0.32/M, $12.40/M
  fi
  dbrk=$dmin${bar:+${dmin:+  }$bar}                          # the same 2-space gap as the rest
fi

# spend rate, dim: a decimal under $10/h, whole dollars above; hidden under $0.10/h
R_rate=""
if [ "$rph" -ge 10 ]; then
  if [ "$rph" -lt 995 ]; then x1=$(( (rph + 5) / 10 )); R_rate="\$$(( x1 / 10 )).$(( x1 % 10 ))/h"
  else R_rate="\$$(( (rph + 50) / 100 ))/h"; fi
  R_rate="${DIM}${R_rate}${RESET}"
fi

# --- layout: identity, then numbers ---
# Quiet by default: no separators and almost no labels; spacing sets the groups apart. Identity
# hues (dir, branch, worktree) and the cost bar are fixed; otherwise only exceptions carry colour
# (dirty tree, behind upstream, context ≥70%, cache expiring or cold, a TTL other than 1h, misses,
# PR state).
L_model="${BOLD}${model}${RESET}"; L_eff=${effort:+ ${DIM}${effort}${RESET}}

# where: the dir's last component, then branch (+ dirty marker, commits ahead/behind upstream,
# linked-worktree name). Unpushed commits are normal (dim); dirty or behind is worth a glance.
L_dir=${dir:+${DIRC}${dir}${RESET}}
s_git=""
if [ -n "$branch" ]; then
  ab=""
  [ "${ahead:-0}" -gt 0 ] 2>/dev/null && ab="${DIM}↑${ahead}${RESET}"
  [ "${behind:-0}" -gt 0 ] 2>/dev/null && ab+="${WARN}↓${behind}${RESET}"
  s_git="${BRANCH}${branch}${RESET}${WARN}${dirty}${RESET}${ab:+ $ab}${wt:+ ${WTC}⎇ ${wt}${RESET}}"
fi

# context: an 8-cell gauge of the window, then the K-tokens in use. Neutral below 70%, WARN from
# 70%, ALERT from 90%. R_ctxs is the gauge-less form for narrow terminals.
R_ctx=""; R_ctxs=""
if [ "$tok" -gt 0 ]; then
  tokK=$(( (tok + 500) / 1000 ))
  fx "$ctx" 0 pct
  if   [ "$pct" -ge 90 ]; then c="$ALERT"
  elif [ "$pct" -ge 70 ]; then c="$WARN"
  else c=""; fi
  clamp f $(( (pct * 8 + 50) / 100 )) 1 8
  printf -v gf '%*s' "$f" ''; printf -v ge '%*s' $(( 8 - f )) ''
  R_ctxs="${c:-$DIM}${tokK}K${RESET}"
  R_ctx="${c}${gf// /━}${RESET}${GRAY}${ge// /─}${RESET} $R_ctxs"
fi

# prompt cache (main conversation): nothing while over 15 min are left (every request resets the
# countdown, so while working it only reads 58-60), then the minutes left in yellow (a nudge to
# send something before it expires), "cold" once it has (the next request then re-caches the
# whole context, which the gauge already shows). A TTL other than 1h always shows, after the
# minutes (3m/5m): on a subscription the main conversation drops to 5m once usage credits kick
# in. Misses (red) carry a short last-cause label and go once 10 min pass with no new miss.
# Hidden if unreported.
# misses fade: a miss is worth a glance while fresh, but the count lingering all session is noise.
# Each new miss restarts a miss_ttl countdown; when it runs out every miss so far is forgotten, so
# <n>✗ counts the misses since the last 10 min without one. State in miss-<sid>: the count
# already forgotten, the count seen at the last refresh (to spot a new miss), and when that new
# miss landed. No file (a new session, or pruned after a week unchanged) forgets what's there, so
# an old count never comes back as new. A render that saw the cost drop once (maybe older JSON
# landing late, see the window) only reads the state.
miss_ttl=600
v_miss=$s_miss
if [ -n "$sid" ]; then
  mf="$cache_dir/miss-$sid"
  if get "$mf" m_base m_seen m_ts; then
    for v in m_base m_seen m_ts; do [[ ${!v} =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
  else m_base=$s_miss; m_seen=$s_miss; m_ts=0; fi
  if [ -z "$stale" ]; then
    [ "$m_base" -gt "$s_miss" ] && m_base=$s_miss            # the baseline moved (compaction, /clear)
    [ "$s_miss" -gt "$m_seen" ] && m_ts=$now                 # a new miss restarts the fade
    m_seen=$s_miss
    [ "$m_ts" -gt 0 ] && [ $(( now - m_ts )) -ge "$miss_ttl" ] && m_base=$s_miss
    put "$mf" "$m_base" "$m_seen" "$m_ts"
  fi
  v_miss=$(( s_miss > m_base ? s_miss - m_base : 0 ))
fi

R_cache=""
if [ "$pc_seen" = true ]; then
  t=""; [ -n "$pc_ttl" ] && [ "$pc_ttl" != 1h ] && t="${WARN}/${pc_ttl}${RESET}"
  left=0; [ "$pc_warm" = true ] && left=999                  # warm, expiry unreported: plenty
  [ "$pc_warm" = true ] && [ -n "$pc_exp" ] && left=$(( (pc_exp - now + 59) / 60 ))
  if [ "$left" -le 0 ]; then R_cache="${WARN}cold${RESET}${t}"
  elif [ -n "$t" ]; then R_cache="${pc_exp:+${DIM}${left}m${RESET}}${t}"  # a short TTL: always
  elif [ "$left" -le 15 ]; then R_cache="${WARN}${left}m${RESET}"         # about to expire
  fi
  [ "$v_miss" -gt 0 ] && R_cache+="${R_cache:+ }${ALERT}${v_miss}✗${RESET}${pc_cause:+ ${DIM}${pc_cause}${RESET}}"
fi

# cost: session total ($0.00 omitted), or only what accrued since the last compaction once a
# baseline exists ($0.00 shown, marking the reset); the rate, $/M and the spend bar follow at
# assembly.
usd "$s_cost" amt; R_cost=""
{ [ -n "$base" ] || [ "$amt" != 0.00 ]; } && R_cost="\$${amt}"

# open PR / MR, coloured by review state
R_pr=""
if [ -n "$pr_num" ]; then
  case "$pr_state" in
    approved)          pc="$GOOD" ;;
    changes_requested) pc="$ALERT" ;;
    pending)           pc="$WARN" ;;
    *)                 pc="$GRAY" ;;
  esac
  R_pr="${pc}#${pr_num}${RESET}"
fi

# --- assemble ---
# $COLUMNS is the terminal width (Claude Code sets it; tput can't see the terminal from here).
# Widths are counted with colour codes stripped (split on ESC, no pattern loop: an extglob took
# seconds per call on a long row), in a UTF-8 locale so ━ ✗ ↑ count as one; `local -` scopes the
# set -f that keeps the dirty marker from globbing. When the row doesn't fit, detail goes in this
# order: the spend bar, the effort, the gauge (tokens stay), $/M, the rate, the dir (branch stays),
# the cache. Without $COLUMNS nothing is fitted.
vis() { local - LC_ALL=C.UTF-8 IFS=$'\033' o a; set -f; a=( $1 )
        o=${a[0]}; a[0]=m; IFS=; o+="${a[*]#*m}"; printf -v "$2" '%s' "${#o}"; }
join() { local v=$1 sep=$2 s o=""; shift 2; for s; do o+=${s:+${o:+$sep}$s}; done; printf -v "$v" '%s' "$o"; }
G="  "
cols=${COLUMNS:-0}; [[ $cols =~ ^[0-9]+$ ]] || cols=0
# Claude Code truncates the status line with "…" once it reaches COLUMNS − 3 (observed), so the
# whole row (leading space included) stays at COLUMNS − 4: W is the room after the leading space.
W=$(( cols - 5 ))
eff=$L_eff; inc=$dbrk; ctxs=$R_ctx; rt=$R_rate; dirs=$L_dir; cache=$R_cache; tried=""
for lvl in 0 1 2 3 4 5 6 7; do
  case $lvl in 1) inc=$dmin ;; 2) eff="" ;; 3) ctxs=$R_ctxs ;; 4) inc="" ;; 5) rt="" ;; 6) dirs="" ;; 7) cache="" ;; esac
  join where " " "$dirs" "$s_git"; join left "$G" "$L_model$eff" "$where"
  join cseg "$G" "$R_cost" "$rt" "$inc"; join right "$G" "$ctxs" "$cache" "$cseg" "$R_pr"
  [ "$cols" -gt 0 ] || break
  [ "$left$G$right" = "$tried" ] && continue; tried=$left$G$right   # this level dropped nothing
  vis "$tried" w; [ "$w" -le "$W" ] && break
done
join row "$G" "$left" "$right"
printf ' %s' "$row"
