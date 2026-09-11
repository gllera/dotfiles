#!/usr/bin/env bash
# Claude Code status line
# Reads the session JSON on stdin and prints one left-aligned row, fitted to $COLUMNS (wrapped here):
#   <model> <effort>  <dir> <branch>* ↑<ahead>↓<behind> ⎇ <worktree>  ━━━━──── <tok>K
#   … ● <min>m[/<ttl>] <hit>% <n>✗ <cause>  (or ○ cold)  $<cost> Δ<increase> ████████  #<pr>
# Nothing is padded: Claude Code doesn't re-run the script on a resize, so a shrink cuts the
# row's end until the next refresh (refreshInterval: 5 s).
# Segments are omitted when empty/zero. Git state is computed locally (cached briefly).
# After a compaction (PostCompact hook in settings.json) the cost, cache hit % and miss count
# restart: they cover only what accrued since it.
# Δ is the last cost increase, to the cent; the 8-cell bar after it splits it by colour in 64ths
# (eighth blocks): green cache read, yellow cache write, red output (+ uncached input), gray
# other. Each increase is also logged with the plan's usage-limit % (usage-<host>.log, in
# $CLAUDE_USAGE_LOG_DIR or cache/statusline).

cache_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/statusline"
# usage log, one file per host so a folder synced between machines never has two writers on one
# file; the analysis merges them by time. Set CLAUDE_USAGE_LOG_DIR in settings.json "env" (not
# only in the statusLine command) so the PostCompact hook, which trims the log, sees it too.
host=${HOSTNAME%%.*}; host=${host//[^A-Za-z0-9_-]/}
ul_dir=${CLAUDE_USAGE_LOG_DIR:-$cache_dir}; ul="$ul_dir/usage-${host:-host}.log"

# PostCompact hook mode (`statusline.sh --compacted`): empty the session's base2-<sid> file, which
# makes the next render snapshot the baseline (see "compaction baseline"), prune week-old cache
# files (usage logs excepted), and trim this host's usage log past 8 MB to its header and last
# 50000 lines. Silent and always exits 0, so it never surfaces as a hook error.
if [ "${1:-}" = --compacted ]; then
  sid=$(jq -r '.session_id // empty' 2>/dev/null); sid=${sid//[^A-Za-z0-9_-]/}
  if [ -n "$sid" ]; then
    mkdir -p "$cache_dir" 2>/dev/null && : > "$cache_dir/base2-$sid" 2>/dev/null
    find "$cache_dir" -type f -mtime +7 ! -name 'usage*.log*' -delete 2>/dev/null
    [ -n "$(find "$ul" -size +8M 2>/dev/null)" ] \
      && { head -n 1 "$ul"; tail -n 50000 "$ul"; } > "$ul.tmp" 2>/dev/null && mv -f "$ul.tmp" "$ul"
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
# Named, so adding a field needs no renumbering. Booleans and null print bare (true/false/null);
# bad JSON prints nothing, leaving every field unset (defaults below). No apostrophes in this
# program: it sits inside single quotes. `exec` spares the subshell a fork.
eval "$(exec jq -r '
  def ttl: startswith("ttl_expired");                          # idle-TTL expiry miss causes
  def num: if type == "number" then floor else null end;       # integer, else null
  def n: num // 0;                                             # counts: integer, else 0
  def short: {system_prompt_changed: "sysprompt", likely_server_side: "server"}[.]
             // (sub("_changed$"; "") | gsub("_"; "-"));        # miss cause → short label
  .context_window as $w | ($w.current_usage // {}) as $u | (.prompt_cache // {}) as $p |
  @sh "model=\(.model.display_name // "Claude") mid=\(.model.id // "") fast=\(.fast_mode)",
  @sh "effort=\(.effort.level // "") cwd=\(.cwd // .workspace.current_dir // "")",
  @sh "wt=\(.workspace.git_worktree // .worktree.name // "") sid=\(.session_id // "")",
  @sh "cost=\(.cost.total_cost_usd // 0) pr_num=\(.pr.number // "") pr_state=\(.pr.review_state // "")",
  @sh "ctx=\($w.used_percentage // "") tok=\($w.total_input_tokens | n)",
  # plan usage limits (subscriptions only): used % and reset epoch, for the usage log
  @sh "rl5=\(.rate_limits.five_hour.used_percentage // "") rl5r=\(.rate_limits.five_hour.resets_at // "")",
  @sh "rl7=\(.rate_limits.seven_day.used_percentage // "") rl7r=\(.rate_limits.seven_day.resets_at // "")",
  # last API request of the main conversation: input, output, cache write, cache read
  @sh "cu_in=\($u.input_tokens | n) cu_out=\($u.output_tokens | n) cu_w=\($u.cache_creation_input_tokens | n) cu_r=\($u.cache_read_input_tokens | n)",
  @sh "pc_seen=\($p.caching_observed) pc_warm=\($p.warm) pc_ttl=\($p.ttl // "")",
  @sh "pc_exp=\($p.expires_at | num // "") pc_h=\($p.hit_ratio // "")",
  @sh "pc_w=\($p.cache_write_tokens | n)",
  # misses and the last miss cause, minus idle-TTL expiries (the cold state already shows those);
  # the cause label gets a "+" when there were several
  @sh "pc_miss=\(try ([($p.misses | n) - ([($p.miss_causes // {}) | to_entries[] | select(.key | ttl) | .value | n] | add // 0), 0] | max) catch 0)",
  @sh "pc_cause=\(try (($p.last_miss_cause.causes // []) | map(strings | select(ttl | not)) | if length == 0 then "" else (.[0] | short) + (if length > 1 then "+" else "" end) end) catch "")"
' 2>/dev/null)"
: "${model:=Claude}"
sid=${sid//[^A-Za-z0-9_-]/}
for v in tok cu_in cu_out cu_w cu_r pc_w pc_miss; do [[ ${!v} =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
model=${model% (*context)}   # "Opus 5 (1M context)" → "Opus 5"
dir=${cwd##*/}; [ "$cwd" = "$HOME" ] && dir="~"                # the cwd's last component

# \x1f-separated cache records (tab is IFS whitespace, so `read` would collapse empty middle fields)
put() { local f=$1 IFS=$'\x1f'; shift; printf '%s\n' "$*" 2>/dev/null > "$f"; }
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

# --- compaction baseline: cost, cache hit % and misses restart at a compaction ---
# The PostCompact hook empties base2-<sid>; the next render snapshots four cumulative counters
# into it (cost in 1/10000 $, total input tokens, cache-write tokens, misses), and each metric
# then shows current − baseline; no baseline reads as zeros, i.e. the whole session. Dropped if
# the cost falls below it (/clear, or a resume resetting it).
# Total input is implied by the hit ratio (in 1e-9): total = (writes + uncached) / (1 - ratio).
# Uncached input is ~0.02% of it in practice, so tin takes total ≈ writes / (1 - ratio), and
# reads ≈ total - writes. That drops uncached / (1 - ratio) — tens of K tokens, roughly
# constant — so the since-% is off by tens of points for the first requests after a compaction.
# It stays hidden until 300K input tokens have accrued since: simulated error < 1 point from
# there, even at 100 uncached tokens per request. Without a baseline the ratio is shown as is.
tin() { if [ "$2" -lt 1000000000 ]; then printf -v "$3" '%s' $(( $1 * 1000000000 / (1000000000 - $2) )); else printf -v "$3" 0; fi; }
fx "$cost" 4 cur
hs=""; [ -n "$pc_h" ] && fx "$pc_h" 9 hs
tin "$pc_w" "${hs:-0}" t_in
base=""
if [ -n "$sid" ]; then
  bf="$cache_dir/base2-$sid"
  [ -f "$bf" ] && [ ! -s "$bf" ] && put "$bf" "$cur" "$t_in" "$pc_w" "$pc_miss"
  get "$bf" b_cost b_t b_w b_miss
  [[ $b_cost =~ ^[0-9]+$ ]] && { if [ "$b_cost" -gt "$cur" ]; then rm -f "$bf"; else base=1; fi; }
fi
[ -n "$base" ] || { b_cost=""; b_t=""; b_w=""; b_miss=""; }
s_cost=$(( cur - b_cost )); s_t=$(( t_in - b_t )); s_w=$(( pc_w - b_w ))   # empty reads as 0
s_miss=$(( pc_miss > b_miss ? pc_miss - b_miss : 0 ))
pc_hit=""
if [ -n "$hs" ]; then
  if [ -z "$base" ]; then pc_hit=$(( (hs * 100 + 500000000) / 1000000000 ))
  elif [ "$s_t" -ge 300000 ]; then clamp pc_hit $(( ((s_t - s_w) * 100 + s_t / 2) / s_t )) 0 100; fi
fi

# --- cost-update breakdown (appended to the session cost) ---
# Claude Code raises cost.total_cost_usd when an API request completes, and current_usage then
# holds that request's final token counts: pricing them reproduces the increase to the
# micro-dollar (verified live). So each increase is split into cache read / cache write / input /
# output from current_usage; whatever that can't explain (subagents, compaction, several requests
# between two refreshes, a model missing from the table) shows as "other", so the parts always sum
# to the increase. The JSON has no request id, so a request's input side (input:write:read tokens)
# stands in for one. Prices are nano-dollars per token (= $/MTok × 1000). State in delta3-<sid>:
# the cost and input side seen at the last refresh, the input side priced last, the shown
# increase and its split (read, write, output + input, other).
p_in=""; rdiv=10; fast_ok=""                                  # read = input / rdiv
case "$mid" in
  claude-opus-5*|claude-opus-4-8*)       p_in=5000;  p_out=25000; fast_ok=1 ;;
  claude-opus-4-7*|claude-opus-4-6*)     p_in=5000;  p_out=25000 ;;
  claude-sonnet-5*)                      p_in=2000;  p_out=10000 ;;
  claude-sonnet-4-6*|claude-sonnet-4-5*) p_in=3000;  p_out=15000 ;;
  claude-haiku-4-5*)                     p_in=1000;  p_out=5000 ;;
  claude-fable-5-1*|claude-mythos-5-1*)  p_in=10000; p_out=50000; rdiv=40 ;;
  claude-fable-5*|claude-mythos-5*)      p_in=10000; p_out=50000 ;;
esac
if [ -n "$p_in" ]; then
  [ "$fast" = true ] && [ -n "$fast_ok" ] && { p_in=$(( p_in * 2 )); p_out=$(( p_out * 2 )); }
  p_r=$(( p_in / rdiv ))
  if [ "$pc_ttl" = 5m ]; then p_w=$(( p_in * 5 / 4 )); else p_w=$(( p_in * 2 )); fi  # write 1.25× / 2×
fi
# price IN W R: the input side's parts, from the NAMES of its token variables (unset reads as 0)
price() { a_i=$(( $1 * p_in )); a_w=$(( $2 * p_w )); a_r=$(( $3 * p_r )); }
tol=5000                                                      # float noise in the reported total
d=""; logd=""
if [ -n "$sid" ]; then
  fx "$cost" 9 cn
  df="$cache_dir/delta3-$sid"; p_cost=""
  get "$df" p_cost l_in l_w l_r pk d pr pw po px
  seen="$cu_in:$cu_w:$cu_r"; last="$l_in:$l_w:$l_r"            # input sides: on screen, seen last time
  if ! [[ $p_cost =~ ^[0-9]+$ ]] || [ "$cn" -lt "$p_cost" ]; then
    d=""                                                      # first refresh, or the cost reset (/clear)
  elif [ "$cn" -gt "$p_cost" ]; then
    d=$(( cn - p_cost )); pr=0; pw=0; po=0; px=$d; li=0; logd=1 # default: all "other"
    # nothing new to price while current_usage still shows the request priced last (subagents
    # finishing while the main conversation is idle, compaction)
    if [ -n "$p_in" ] && [ "$seen" != "$pk" ]; then
      price cu_in cu_w cu_r; a_o=$(( cu_out * p_out ))
      x=$(( d - a_r - a_w - a_i - a_o )); k=$seen
      # this refresh already shows the next request in flight: price the one seen last time (if
      # not priced yet) from that earlier view, its output being the remainder
      if [ "${x#-}" -gt "$tol" ] && [[ $l_r =~ ^[0-9]+$ ]] && [ $(( cu_in + cu_w + cu_r )) -gt 0 ] \
         && [ "$last" != "$seen" ] && [ "$last" != "$pk" ]; then
        price l_in l_w l_r; o=$(( d - a_r - a_w - a_i ))
        if [ "$o" -ge 0 ] && [ $(( o / p_out )) -le 128000 ]; then a_o=$o; x=0; k=$last
        else price cu_in cu_w cu_r; fi                        # rejected: back to the current view
      fi
      [ "${x#-}" -le "$tol" ] && x=0
      [ "$x" -ge 0 ] && { pr=$a_r; pw=$a_w; po=$(( a_o + a_i )); li=$a_i; px=$x; pk=$k; }   # else unexplained: all other
    fi
  fi
  put "$df" "$cn" "$cu_in" "$cu_w" "$cu_r" "$pk" "$d" "$pr" "$pw" "$po" "$px"
  # usage log: a line per increase with the plan's usage-limit % at that moment, to fit how much
  # each part weighs on the 5-hour / weekly limits (Anthropic doesn't document it). Tab-separated,
  # money in nano-dollars, output and uncached input apart (they may weigh differently); only when
  # the JSON carries rate limits (subscriptions). Overlapping renders can log an increase twice,
  # so dedupe on sid + cost (cumulative) when analysing. The header is appended, never truncating.
  if [ -n "$logd" ] && [ -n "$rl5$rl7" ]; then
    [ -f "$ul" ] || { mkdir -p "$ul_dir" 2>/dev/null; printf '#ts\tsid\tmodel\tfast\tttl\tcost\tdelta\tread\twrite\tout\tin\tother\tpct5h\treset5h\tpct7d\treset7d\n' 2>/dev/null >> "$ul"; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$sid" "$mid" "$fast" "$pc_ttl" \
      "$cn" "$d" "$pr" "$pw" $(( po - li )) "$li" "$px" "$rl5" "$rl5r" "$rl7" "$rl7r" 2>/dev/null >> "$ul"
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
dbrk=""; dmin=""                                              # "Δ.xx <bar>" and plain "Δ.xx"
if [[ $d =~ ^[0-9]+$ ]]; then
  dc=$(( (d + 5000000) / 10000000 ))                          # nano-dollars → cents
  if [ "$dc" -gt 0 ]; then
    cfmt "$dc" dmin; dmin="${DIM}Δ${dmin#0}${RESET}"              # Δ.32, Δ1.24
    bar=""; bar8 bar "${pr:-0}" "${pw:-0}" "${po:-0}" "${px:-0}"
    dbrk=$dmin${bar:+ $bar}
  fi
fi

# --- layout: identity, then numbers ---
# Quiet by default: no separators and almost no labels; spacing sets the groups apart. Identity
# hues (dir, branch, worktree) and the cost bar are fixed; otherwise only exceptions carry colour
# (dirty tree, behind upstream, context ≥70%, cold cache, a TTL other than 1h, misses, PR state).
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

# prompt cache (main conversation): ● and the minutes left while warm; ○ cold once it expires
# (the next request then re-caches the whole context, which the gauge already shows). A TTL other
# than 1h follows the minutes (3m/5m): on a subscription the main conversation drops to 5m once
# usage credits kick in. The hit % only shows below 90%; misses (red) carry a short last-cause
# label. Hidden if unreported.
R_cache=""
if [ "$pc_seen" = true ]; then
  t=""; [ -n "$pc_ttl" ] && [ "$pc_ttl" != 1h ] && t="${WARN}/${pc_ttl}${RESET}"
  left=0
  [ "$pc_warm" = true ] && [ -n "$pc_exp" ] && left=$(( (pc_exp - now + 59) / 60 ))
  if [ "$left" -gt 0 ]; then
    R_cache="${GRAY}●${RESET} ${DIM}${left}m${RESET}${t}"
    [ -n "$pc_hit" ] && [ "$pc_hit" -lt 90 ] && R_cache+=" ${DIM}${pc_hit}%${RESET}"
  else
    R_cache="${WARN}○ cold${RESET}${t}"
  fi
  [ "$s_miss" -gt 0 ] && R_cache+=" ${ALERT}${s_miss}✗${RESET}${pc_cause:+ ${DIM}${pc_cause}${RESET}}"
fi

# cost: session total ($0.00 omitted), or only what accrued since the last compaction once a
# baseline exists ($0.00 shown, marking the reset); the last increase (Δ) and its colour bar
# follow at assembly.
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
# seconds per call on a long row), in a UTF-8 locale so ━ ● ↑ count as one; `local -` scopes the
# set -f that keeps the dirty marker from globbing. When the row doesn't fit, detail goes in this
# order: the increase's split, the effort, the gauge (tokens stay), the increase, the dir (branch
# stays), the cache. Without $COLUMNS nothing is fitted.
vis() { local - LC_ALL=C.UTF-8 IFS=$'\033' o a; set -f; a=( $1 )
        o=${a[0]}; a[0]=m; IFS=; o+="${a[*]#*m}"; printf -v "$2" '%s' "${#o}"; }
join() { local v=$1 sep=$2 s o=""; shift 2; for s; do o+=${s:+${o:+$sep}$s}; done; printf -v "$v" '%s' "$o"; }
G="  "
cols=${COLUMNS:-0}; [[ $cols =~ ^[0-9]+$ ]] || cols=0
# Claude Code truncates the status line with "…" once it reaches COLUMNS − 3 (observed), so the
# whole row (leading space included) stays at COLUMNS − 4: W is the room after the leading space.
W=$(( cols - 5 ))
eff=$L_eff; inc=$dbrk; ctxs=$R_ctx; dirs=$L_dir; cache=$R_cache; tried=""
for lvl in 0 1 2 3 4 5 6; do
  case $lvl in 1) inc=$dmin ;; 2) eff="" ;; 3) ctxs=$R_ctxs ;; 4) inc="" ;; 5) dirs="" ;; 6) cache="" ;; esac
  join where " " "$dirs" "$s_git"; join left "$G" "$L_model$eff" "$where"
  join cseg " " "$R_cost" "$inc"; join right "$G" "$ctxs" "$cache" "$cseg" "$R_pr"
  [ "$cols" -gt 0 ] || break
  [ "$left$G$right" = "$tried" ] && continue; tried=$left$G$right   # this level dropped nothing
  vis "$tried" w; [ "$w" -le "$W" ] && break
done
join row "$G" "$left" "$right"
printf ' %s' "$row"
