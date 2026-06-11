#!/usr/bin/env bash
# Claude Code status line — single-line, full
# Reads the session JSON on stdin and prints one colored status row:
#   <model> <effort> · <dir> · <branch>* · ctx <pct>% · $<cost> · +<add> -<del> · PR #<n>
# Segments are omitted when empty/zero. Git state is computed locally (cached briefly).

input=$(cat)

# --- colors ---
RESET=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
MAGENTA=$'\033[35m'; CYAN=$'\033[36m'; GRAY=$'\033[90m'

# --- pull fields in one jq pass (one per line; empties preserved by mapfile) ---
mapfile -t F < <(printf '%s' "$input" | jq -r '
  (.model.display_name // "Claude"),
  (.effort.level // ""),
  (.cwd // .workspace.current_dir // ""),
  ((.context_window.used_percentage // "") | tostring),
  ((.cost.total_cost_usd // 0) | tostring),
  ((.cost.total_lines_added // 0) | tostring),
  ((.cost.total_lines_removed // 0) | tostring),
  ((.pr.number // "") | tostring),
  (.pr.review_state // ""),
  ((.context_window.total_input_tokens // 0) | tostring)
' 2>/dev/null)
model=${F[0]:-Claude}; effort=${F[1]}; cwd=${F[2]}; ctx=${F[3]}
cost=${F[4]:-0}; added=${F[5]:-0}; removed=${F[6]:-0}; pr_num=${F[7]}; pr_state=${F[8]}
tok=${F[9]:-0}

# --- pretty cwd: collapse $HOME to ~, shorten very long paths to …/last2 ---
dir="$cwd"
case "$dir" in
  "$HOME")   dir="~" ;;
  "$HOME"/*) dir="~/${dir#"$HOME"/}" ;;
esac
if [ "${#dir}" -gt 28 ]; then
  dir="…/$(printf '%s' "$dir" | rev | cut -d/ -f1-2 | rev)"
fi

# --- git branch + dirty (cached 3s per-cwd to stay snappy in big repos) ---
branch=""; dirty=""
if [ -n "$cwd" ]; then
  cache_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/statusline"; mkdir -p "$cache_dir" 2>/dev/null
  key=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)
  cf="$cache_dir/git-$key"
  now=$(date +%s)
  if [ -f "$cf" ] && [ $(( now - $(stat -c %Y "$cf" 2>/dev/null || echo 0) )) -lt 3 ]; then
    IFS=$'\t' read -r branch dirty < "$cf"
  else
    if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
      [ -z "$branch" ] && branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
      [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ] && dirty="*"
    fi
    printf '%s\t%s\n' "$branch" "$dirty" > "$cf"
  fi
fi

# --- assemble: join non-empty segments with " · " ---
sep="${GRAY} · ${RESET}"; out=""
add() { [ -z "$1" ] && return; if [ -z "$out" ]; then out="$1"; else out="$out$sep$1"; fi; }

# model (+ effort)
seg="${BOLD}${model}${RESET}"
[ -n "$effort" ] && seg="$seg ${DIM}${effort}${RESET}"
add "$seg"

# dir
[ -n "$dir" ] && add "${CYAN}${dir}${RESET}"

# branch (+ dirty marker)
[ -n "$branch" ] && add "${MAGENTA}${branch}${RED}${dirty}${RESET}"

# context: K-tokens only (color still reflects % usage; % not shown)
tokK=0
[ "${tok:-0}" -gt 0 ] 2>/dev/null && tokK=$(( (tok + 500) / 1000 ))
if [ "$tokK" -gt 0 ] 2>/dev/null; then
  pct=$(printf '%.0f' "${ctx:-0}" 2>/dev/null); pct=${pct:-0}
  if   [ "$pct" -ge 90 ]; then c="$RED"
  elif [ "$pct" -ge 70 ]; then c="$YELLOW"
  else c="$GREEN"; fi
  add "${DIM}ctx ${RESET}${c}${tokK}K${RESET}"
fi

# cost (omit $0.00)
cost_fmt=$(printf '%.2f' "$cost" 2>/dev/null)
[ -n "$cost_fmt" ] && [ "$cost_fmt" != "0.00" ] && add "${DIM}\$${cost_fmt}${RESET}"

# lines changed (omit when both zero)
added=${added:-0}; removed=${removed:-0}
if [ "$added" -gt 0 ] 2>/dev/null || [ "$removed" -gt 0 ] 2>/dev/null; then
  add "${GREEN}+${added}${RESET} ${RED}-${removed}${RESET}"
fi

# open PR badge (colored by review state)
if [ -n "$pr_num" ]; then
  case "$pr_state" in
    approved)          pc="$GREEN" ;;
    changes_requested) pc="$RED" ;;
    pending)           pc="$YELLOW" ;;
    *)                 pc="$GRAY" ;;
  esac
  add "${pc}PR #${pr_num}${RESET}"
fi

printf ' %s' "$out"
