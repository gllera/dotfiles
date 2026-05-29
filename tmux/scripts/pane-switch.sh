#!/usr/bin/env bash
# tmux pane switching — fzf-driven navigation between panes.
#
#   pane-switch.sh switch   # (Alt+j) fzf-pick ANY pane (addr · path · process · title), then jump
#   pane-switch.sh jump     # (Alt+J) go to the next Claude pane awaiting your input (wait)
#   pane-switch.sh back     # (Alt+k) return to the pane you last jumped from (toggles)
#
# 'jump' reads the per-pane @claude_state that claude-tmux.sh paints, to hop to the
# next Claude pane in the 'wait' state (awaiting your input); notifies if none.
# 'switch' lists every pane on the server (its
# address, path, process and title) and jumps to the one you pick. Both record the
# pane you leave in @pane_prev; 'back' jumps there and re-records the pane you left,
# so pressing it again returns — a cross-session "last pane" toggle.
# None of them change @claude_state. All subcommands no-op outside tmux.
set -u

in_tmux() { [ -n "${TMUX:-}" ]; }
have()    { command -v "$1" >/dev/null 2>&1; }
msg()     { tmux display-message "$1"; }

# Explicit pane title for display, or '-' when there is none. tmux's default title is
# the host and TUI apps (Claude Code) clear it to "" on exit, so treat host/empty as
# "no title" (same test as pane-border-format in tmux.conf). When there's no real
# pane_title, fall back to @static_title — the label the `twin` helper paints on panes
# it spawns (e.g. `ec eu-3:1`); it stores the command in that pane option, not in
# pane_title, which stays at the host default. Only then collapse to '-'. Non-empty
# either way, so it never collapses the TAB-split below. The process is shown
# separately, so this no longer falls back to the command.
_title_fmt='#{?#{||:#{==:#{pane_title},#{host}},#{==:#{pane_title},}},#{?#{!=:#{@static_title},},#{@static_title},-},#{pane_title}}'

# _goto <pane-id> — move the active client to that pane, crossing session/window as
# needed. Returns non-zero (and moves nothing) if the pane no longer exists.
_goto() {
  local p=$1 s w
  s=$(tmux display-message -p -t "$p" '#{session_name}' 2>/dev/null) || return 1
  [ -n "$s" ] || return 1
  w=$(tmux display-message -p -t "$p" '#{window_id}' 2>/dev/null) || return 1
  tmux switch-client -t "$s"
  tmux select-window -t "$w"
  tmux select-pane   -t "$p"
}

# jump — switch to the next PANE awaiting your input: a Claude in the 'wait' state
# (red ◆). If none is waiting, notify and stay put — jump no longer falls back to
# 'done' panes, so it's strictly for Claudes asking for you.
cmd_jump() {
  in_tmux || exit 0
  # $1 is the pane we're leaving, passed by the binding as #{pane_id}: run-shell
  # children don't inherit $TMUX_PANE, so the origin must be handed to us explicitly.
  local origin=${1:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}
  # first Claude pane (server-wide) in the 'wait' state — just its pane id; _goto
  # re-derives the session and window from it.
  local target
  target=$(tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{@claude_state}' \
    | awk '$2 == "claude" && $3 == "wait" { print $1; exit }')
  [ -z "$target" ] && { msg "no Claude pane needs your input"; exit 0; }
  # remember where we came from so 'back' can return (skip if we're already there)
  [ -n "$origin" ] && [ "$origin" != "$target" ] && tmux set-option -g @pane_prev "$origin"
  _goto "$target"
}

# switch — fzf over EVERY pane on the server and jump to the pick. Columns are
# address · path · process, each sized to hug its content; the free-form title comes
# last (so a long/unicode one can't skew the rest). The Alt+j binding stashes the origin
# pane in @pane_origin first (a popup can't read it reliably); on a real pick we copy
# that to @pane_prev so 'back' can return.
cmd_switch() {
  in_tmux || exit 0
  have fzf || { msg "fzf not found"; exit 0; }
  local rows sel pid tilde='~' tab=$'\t'
  # A '-' placeholder keeps an empty title from collapsing the TAB-split (read with
  # IFS=$'\t' merges adjacent tabs); process and path are always non-empty. $tab
  # keeps literal tabs out of the source.
  rows=$(tmux list-panes -a \
          -F "#{pane_id}${tab}#{pane_current_command}${tab}${_title_fmt}${tab}#{session_name}:#{window_index}.#{pane_index}${tab}#{pane_current_path}")
  [ -z "$rows" ] && { msg "no panes open"; exit 0; }

  # First pass: widest address / process / path, so each column hugs its content
  # (no guessed fixed widths, so short names don't leave big gaps).
  local wa=0 wc=0 wp=0 _c _a _p _pp
  while IFS=$'\t' read -r _ _c _ _a _p; do
    _pp=${_p/#$HOME/$tilde}
    (( ${#_a}  > wa )) && wa=${#_a}
    (( ${#_c}  > wc )) && wc=${#_c}
    (( ${#_pp} > wp )) && wp=${#_pp}
  done <<< "$rows"

  sel=$(printf '%s\n' "$rows" | while IFS=$'\t' read -r pid cmd title addr path; do
          printf '%s\t%-*s  %-*s  %-*s  %s\n' \
            "$pid" "$wa" "$addr" "$wp" "${path/#$HOME/$tilde}" "$wc" "$cmd" "$title"
        done | fzf --reverse --with-nth=2.. --delimiter=$'\t' --prompt='')
  [ -z "$sel" ] && exit 0
  pid=${sel%%$'\t'*}
  # copy the stashed origin (set by the J binding) to @pane_prev so 'back' returns here
  local origin; origin=$(tmux show-options -gqv @pane_origin)
  [ -n "$origin" ] && [ "$origin" != "$pid" ] && tmux set-option -g @pane_prev "$origin"
  _goto "$pid"
}

# back — return to the pane recorded in @pane_prev (set by jump/switch above), leaving
# the pane we're in now as the new @pane_prev so repeated presses toggle between them.
cmd_back() {
  in_tmux || exit 0
  # $1 is the pane we're in, passed by the binding as #{pane_id} (run-shell children
  # have no $TMUX_PANE). Go to @pane_prev, then store $1 as the new @pane_prev so a
  # second press comes straight back — toggling back and forth between the two panes.
  local cur=${1:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)} prev
  prev=$(tmux show-options -gqv @pane_prev)
  [ -n "$prev" ] || { msg "no pane to jump back to"; exit 0; }
  # Already on the recorded pane (e.g. you navigated here by hand): nothing to toggle
  # to. Notify and stop — otherwise the no-op '&&' record below returns 1, which tmux
  # surfaces as a "returned 1" popup even though nothing actually went wrong.
  [ "$cur" = "$prev" ] && { msg "already on the last-visited pane"; exit 0; }
  _goto "$prev" || { msg "previous pane is gone"; tmux set-option -gu @pane_prev; exit 0; }
  # Record where we just left so a second press toggles back (cur != prev here). An
  # `if` rather than a trailing '&&' chain: when cur is empty the chain would exit 1
  # and raise a spurious tmux error even though 'back' succeeded.
  if [ -n "$cur" ]; then tmux set-option -g @pane_prev "$cur"; fi
}

sub=${1:-}; shift || true
case "$sub" in
  jump)   cmd_jump "$@" ;;
  switch) cmd_switch "$@" ;;
  back)   cmd_back "$@" ;;
  *) echo "usage: pane-switch.sh {jump | switch | back}" >&2; exit 2 ;;
esac
