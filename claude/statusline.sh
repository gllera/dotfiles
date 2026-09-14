#!/usr/bin/env bash
# Claude Code status line
# Reads the session JSON on stdin and prints one left-aligned row, fitted to $COLUMNS (wrapped here):
#   <model> <effort>  [⎇ ]<dir> <branch>* ↑<ahead>↓<behind>  ━━━━──── <tok>K
#   … [<min>m][/<ttl>] <n>✗ <cause>  (or cold)  $<cost>  $<rate>/h  ⇣$<saves>/h  $<per 1M>/M  ████████  #<pr>
# Nothing is padded: Claude Code doesn't re-run the script on a resize, so a shrink cuts the
# row's end until the next refresh (refreshInterval: 5 s).
# Segments are omitted when empty/zero. Git state is computed locally (cached briefly).
# Spend comes from claude-spend (`claude-spend session`, JSON; source in ~/tempo/statusline),
# which prices the session's transcripts and reads its compactions from them: the cost since the
# last compaction (the whole session before one; $0.00 right after one), the spend rate over the
# last 15 min ($/h), then the 8-cell bar splitting the spend on the last ~5M tokens, subagents
# included, by colour in 64ths (eighth blocks): green cache read, yellow cache write, red output
# (+ uncached input), gray other; $/M before it is their cost per 1M tokens. ⇣$<saves>/h, in
# yellow, shows when compacting now would pay for itself within 15 min at the current pace: what
# it would save per hour. claude-spend also records the plan's usage-limit % for the tmux badge.
# Without claude-spend (not installed, or failing) the row shows the session's reported cost alone.

cache_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/statusline"
spend_bin=${CLAUDE_SPEND_BIN:-claude-spend}

# `--compacted` was the PostCompact hook's mode; claude-spend reads compactions from the
# transcript now, so a hook entry left behind does nothing.
[ "${1:-}" = --compacted ] && exit 0

now=$EPOCHSECONDS
[ -d "$cache_dir" ] || mkdir -p "$cache_dir" 2>/dev/null

# --- colors: quiet by default, colour only when something needs attention ---
# Identity hues are fixed and never a signal (dir, branch, worktree); metrics stay default or
# dim while healthy. Signals use tmux's 256-colour codes so they match the Claude state markers
# on the pane borders: WARN 220 (attention), ALERT 196 (act now), GOOD 40 (PR approved only).
RESET=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; GRAY=$'\033[90m'
DIRC=$'\033[34m'; BRANCH=$'\033[95m'; WTC=$'\033[2;95m'
WARN=$'\033[38;5;220m'; ALERT=$'\033[38;5;196m'; GOOD=$'\033[38;5;40m'

# --- fields: one jq pass over stdin and claude-spend's answer, emitting shell-quoted (@sh)
# assignments that are eval'd ---
# Named, so adding a field needs no renumbering. Booleans and null print bare (true/false/null),
# arrays and objects empty (@sh would print an array as several words, which eval would run);
# bad JSON on stdin prints nothing, leaving every field unset (defaults below); no answer from
# claude-spend leaves its fields (s_*) empty. Dollars arrive as integer cents. No apostrophes in
# this program: it sits inside single quotes. `exec` spares the subshell a fork; stdin is read by
# `read` and both documents reach jq in one here-string, so no cat or pipe forks either.
IFS= read -r -d '' input
spend=""; command -v "$spend_bin" >/dev/null 2>&1 && spend=$("$spend_bin" session <<<"$input" 2>/dev/null)
eval "$(exec jq -nr '
  def ttl: startswith("ttl_expired");                          # idle-TTL expiry miss causes
  def num: if type == "number" then floor else null end;       # integer, else null
  def n: num // 0;                                             # counts: integer, else 0
  def cents: if type == "number" then . * 100 | round else null end;   # dollars → cents
  def short: {system_prompt_changed: "sysprompt", likely_server_side: "server"}[.]
             // (sub("_changed$"; "") | gsub("_"; "-"));        # miss cause → short label
  def v: if type == "array" or type == "object" then "" else . end;   # scalars only
  (try input catch {}) as $in | ((try input catch null) // {}) as $s |
  $in | .context_window as $w | (.prompt_cache // {}) as $p |
  @sh "model=\(.model.display_name // "Claude" | v) effort=\(.effort.level // "" | v)",
  @sh "cwd=\(.cwd // .workspace.current_dir // "" | v) wt=\(.workspace.git_worktree // .worktree.name // "" | v)",
  @sh "sid=\(.session_id // "" | v) cost=\(.cost.total_cost_usd | cents // 0)",
  @sh "pr_num=\(.pr.number // "" | v) pr_state=\(.pr.review_state // "" | v)",
  @sh "ctx=\($w.used_percentage // "" | v) tok=\($w.total_input_tokens | n)",
  @sh "pc_seen=\($p.caching_observed | v) pc_warm=\($p.warm | v) pc_ttl=\($p.ttl // "" | v) pc_exp=\($p.expires_at | num // "")",
  # misses and the last miss cause, minus idle-TTL expiries (the cold state already shows those);
  # the cause label gets a "+" when there were several
  @sh "pc_miss=\(try ([($p.misses | n) - ([($p.miss_causes // {}) | to_entries[] | select(.key | ttl) | .value | n] | add // 0), 0] | max) catch 0)",
  @sh "pc_cause=\(try (($p.last_miss_cause.causes // []) | map(strings | select(ttl | not)) | if length == 0 then "" else (.[0] | short) + (if length > 1 then "+" else "" end) end) catch "")",
  # claude-spend: the cost since the last compaction and when that was, the rate, $/M, the
  # bar split in 64ths, the compaction advice and its hourly saving
  @sh "s_ok=\($s.v // "" | v) s_ro=\($s.read_only // false | v) s_cost=\($s.cost.since_compaction_usd | cents // "")",
  @sh "s_priced=\($s.cost.priced_usd // "" | v)",
  @sh "s_cmp=\($s.cost.compacted // false | v) s_cat=\($s.cost.compacted_at // "" | v) s_rate=\($s.rate.usd_per_hour | cents // 0)",
  @sh "s_mtok=\($s.window.usd_per_mtok | cents // 0) s_split=\(($s.window.split64 // []) | map(tostring) | join(" "))",
  @sh "s_adv=\($s.context.compact.advise // false | v) s_save=\($s.context.compact.saves_usd_per_hour | cents // 0)"
' 2>/dev/null <<<"$input"$'\n'"$spend")"
: "${model:=Claude}"
sid=${sid//[^A-Za-z0-9_-]/}
for v in tok pc_miss cost s_rate s_mtok s_save; do [[ ${!v} =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
model=${model% (*context)}   # "Opus 5 (1M context)" → "Opus 5"
dir=${cwd##*/}; [ "$cwd" = "$HOME" ] && dir="~"                # the cwd's last component

# \x1f-separated cache records (tab is IFS whitespace, so `read` would collapse empty middle fields)
# put writes a temp file and renames it over, so an overlapping render never reads it half-written;
# unchanged content (most refreshes) isn't rewritten, sparing the mv
put() { local f=$1 IFS=$'\x1f' o; shift; { IFS= read -r o < "$f"; } 2>/dev/null; [ "$o" = "$*" ] && return
        printf '%s\n' "$*" 2>/dev/null > "$f.$$" && mv -f "$f.$$" "$f" 2>/dev/null; }
get() { local _f=$1; shift; [ -f "$_f" ] && IFS=$'\x1f' read -r "$@" < "$_f"; }

# once a day, drop cache files unchanged for a week
get "$cache_dir/pruned" p_day
if [ "${p_day:-}" != $(( now / 86400 )) ]; then
  find "$cache_dir" -type f -mtime +7 -delete 2>/dev/null
  put "$cache_dir/pruned" $(( now / 86400 ))
fi

# --- badge redraw: ask tmux to redraw its status bar, whose claude-usage.sh badge shows this
# account's spend and limit estimate, when this session's priced spend moved; at most every 2 s
# across sessions, as tmux kills a badge run still in flight when asked again (claude-spend v3
# §5.3). In the background with no output, so the row never waits on it. ---
if [ -n "${TMUX:-}" ] && [ -n "$sid" ] && [ -n "$s_priced" ] && [ "$s_ro" != true ]; then
  get "$cache_dir/poke-$sid" p_seen
  if [ "${p_seen:-}" != "$s_priced" ]; then
    get "$cache_dir/poke" p_last
    if ! [[ ${p_last:-} =~ ^[0-9]+$ ]] || [ $(( now - p_last )) -ge 2 ]; then
      put "$cache_dir/poke" "$now"; put "$cache_dir/poke-$sid" "$s_priced"
      { tmux list-clients -F '#{client_name}' 2>/dev/null | while IFS= read -r c; do
          tmux refresh-client -S -t "$c" 2>/dev/null; done; } </dev/null >/dev/null 2>&1 &
    fi
  fi
fi

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
# octal); cfmt prints cents as d.dd; perh prints cents per hour: a decimal under $10/h, whole
# dollars above, nothing under $0.10/h.
fx() { local v; printf -v v "%.${2}f" "${1:-0}" 2>/dev/null || v=0; v=${v/./}; printf -v "$3" '%s' $(( 10#$v )); }
cfmt() { printf -v "$2" '%d.%02d' $(( $1 / 100 )) $(( $1 % 100 )); }
perh() { local _d; printf -v "$2" ''                           # (a local named like the caller's VAR would hide it)
         if [ "$1" -ge 995 ]; then printf -v "$2" '$%d/h' $(( ($1 + 50) / 100 ))
         elif [ "$1" -ge 10 ]; then _d=$(( ($1 + 5) / 10 )); printf -v "$2" '$%d.%d/h' $(( _d / 10 )) $(( _d % 10 )); fi; }
clamp() { printf -v "$1" '%s' $(( $2 < $3 ? $3 : $2 > $4 ? $4 : $2 )); }   # VAR value lo hi

# bar64 VAR READ WRITE OUT OTHER: the 8-cell bar of a split already in 64ths (claude-spend's
# split64, whose boundaries leave no cell holding more than two parts). Green and red are softer
# than GOOD/ALERT, whose meanings are reserved; yellow is WARN's. A cell holding a boundary draws
# its left part as the partial block's foreground and the next as its background, so edges stay
# sharp. A split that doesn't add up to 64 draws nothing.
bar64() {
  local out=$1 F=( '38;5;71' '38;5;220' '38;5;167' 90 ) B=( '48;5;71' '48;5;220' '48;5;167' 100 )
  local eighth=( '' ▏ ▎ ▍ ▌ ▋ ▊ ▉ ) fg=() bg=() n=() i=0 t=0 s="" x p e c lo
  shift
  for x in "$@"; do
    [[ $x =~ ^[0-9]+$ ]] && [ "$x" -gt 0 ] && { n+=( "$x" ); fg+=( "${F[i]}" ); bg+=( "${B[i]}" ); t=$(( t + x )); }
    i=$(( i + 1 ))
  done
  [ "$t" -eq 64 ] || return
  p=0; e=${n[0]}                                              # part p covers the cell start, ends at e
  for c in 0 1 2 3 4 5 6 7; do
    lo=$(( c * 8 ))
    while [ "$e" -le "$lo" ]; do p=$(( p + 1 )); e=$(( e + n[p] )); done
    if [ "$e" -ge $(( lo + 8 )) ]; then s+=$'\033[0;'"${fg[p]}m█"
    else s+=$'\033[0;'"${fg[p]};${bg[p+1]}m${eighth[e - lo]}"; fi
  done
  printf -v "$out" '%s' "$s$RESET"
}

# --- spend: cost, rate, compaction hint, $/M and the bar, from claude-spend ---
# The cost is what accrued since the last compaction ($0.00 shown right after one, marking the
# reset), the whole session before any ($0.00 omitted). Without claude-spend: the reported cost.
R_cost=""; R_rate=""; R_adv=""; dmin=""; dbrk=""
if [ -n "$s_ok" ] && [[ $s_cost =~ ^[0-9]+$ ]]; then
  cfmt "$s_cost" amt
  { [ "$s_cmp" = true ] || [ "$amt" != 0.00 ]; } && R_cost="\$${amt}"
  perh "$s_rate" x; [ -n "$x" ] && R_rate="${DIM}${x}${RESET}"
  if [ "$s_adv" = true ]; then perh "$s_save" x; [ -n "$x" ] && R_adv="${WARN}⇣${x}${RESET}"; fi
  [ "$s_mtok" -gt 0 ] && { cfmt "$s_mtok" dmin; dmin="${DIM}\$${dmin}/M${RESET}"; }   # $0.32/M, $12.40/M
  bar=""; [ -n "$s_split" ] && bar64 bar $s_split
  dbrk=$dmin${bar:+${dmin:+  }$bar}                           # the same 2-space gap as the rest
else
  cfmt "$cost" amt; [ "$amt" != 0.00 ] && R_cost="\$${amt}"
fi

# --- layout: identity, then numbers ---
# Quiet by default: no separators and almost no labels; spacing sets the groups apart. Identity
# hues (dir, branch, worktree) and the cost bar are fixed; otherwise only exceptions carry colour
# (dirty tree, behind upstream, context ≥70%, cache expiring or cold, a TTL other than 1h, misses,
# the compaction hint, PR state).
L_model="${BOLD}${model}${RESET}"; L_eff=${effort:+ ${DIM}${effort}${RESET}}

# where: the dir's last component (prefixed with ⎇ when in a linked worktree), then branch
# (+ dirty marker, commits ahead/behind upstream). Unpushed commits are normal (dim); dirty or
# behind is worth a glance.
L_dir=${dir:+${wt:+${WTC}⎇ ${RESET}}${DIRC}${dir}${RESET}}
s_git=""
if [ -n "$branch" ]; then
  ab=""
  [ "${ahead:-0}" -gt 0 ] 2>/dev/null && ab="${DIM}↑${ahead}${RESET}"
  [ "${behind:-0}" -gt 0 ] 2>/dev/null && ab+="${WARN}↓${behind}${RESET}"
  s_git="${BRANCH}${branch}${RESET}${WARN}${dirty}${RESET}${ab:+ $ab}"
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
# <n>✗ counts the misses since the last 10 min without one. A compaction (claude-spend's
# compacted_at moving) forgets them too, as the cost restarts there. State in miss2-<sid>: the
# count already forgotten, the count seen at the last refresh (to spot a new miss), when that new
# miss landed, and the compaction last seen. No file (a new session, or pruned after a week
# unchanged) forgets what's there, so an old count never comes back as new. A render that didn't
# get claude-spend's session lock (read_only) only reads the state.
miss_ttl=600
v_miss=$pc_miss
if [ -n "$sid" ]; then
  mf="$cache_dir/miss2-$sid"
  if get "$mf" m_base m_seen m_ts m_cat; then
    for v in m_base m_seen m_ts; do [[ ${!v} =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
  else m_base=$pc_miss; m_seen=$pc_miss; m_ts=0; m_cat=$s_cat; fi
  if [ "$s_ro" != true ]; then
    [ "$m_base" -gt "$pc_miss" ] && m_base=$pc_miss            # the count went down (/clear)
    [ -n "$s_cat" ] && [ "$s_cat" != "$m_cat" ] && { m_base=$pc_miss; m_cat=$s_cat; }   # compacted
    [ "$pc_miss" -gt "$m_seen" ] && m_ts=$now                  # a new miss restarts the fade
    m_seen=$pc_miss
    [ "$m_ts" -gt 0 ] && [ $(( now - m_ts )) -ge "$miss_ttl" ] && m_base=$pc_miss
    put "$mf" "$m_base" "$m_seen" "$m_ts" "$m_cat"
  fi
  v_miss=$(( pc_miss > m_base ? pc_miss - m_base : 0 ))
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
# order: the spend bar, the effort, the gauge (tokens stay), $/M, the rate and the compaction
# hint, the dir (branch stays), the cache. Without $COLUMNS nothing is fitted.
vis() { local - LC_ALL=C.UTF-8 IFS=$'\033' o a; set -f; a=( $1 )
        o=${a[0]}; a[0]=m; IFS=; o+="${a[*]#*m}"; printf -v "$2" '%s' "${#o}"; }
join() { local v=$1 sep=$2 s o=""; shift 2; for s; do o+=${s:+${o:+$sep}$s}; done; printf -v "$v" '%s' "$o"; }
G="  "
cols=${COLUMNS:-0}; [[ $cols =~ ^[0-9]+$ ]] || cols=0
# Claude Code truncates the status line with "…" once it reaches COLUMNS − 3 (observed), so the
# whole row (leading space included) stays at COLUMNS − 4: W is the room after the leading space.
W=$(( cols - 5 ))
eff=$L_eff; inc=$dbrk; ctxs=$R_ctx; rt=$R_rate; adv=$R_adv; dirs=$L_dir; cache=$R_cache; tried=""
for lvl in 0 1 2 3 4 5 6 7; do
  case $lvl in 1) inc=$dmin ;; 2) eff="" ;; 3) ctxs=$R_ctxs ;; 4) inc="" ;; 5) rt=""; adv="" ;; 6) dirs="" ;; 7) cache="" ;; esac
  join where " " "$dirs" "$s_git"; join left "$G" "$L_model$eff" "$where"
  join cseg "$G" "$R_cost" "$rt" "$adv" "$inc"; join right "$G" "$ctxs" "$cache" "$cseg" "$R_pr"
  [ "$cols" -gt 0 ] || break
  [ "$left$G$right" = "$tried" ] && continue; tried=$left$G$right   # this level dropped nothing
  vis "$tried" w; [ "$w" -le "$W" ] && break
done
join row "$G" "$left" "$right"
printf ' %s' "$row"
