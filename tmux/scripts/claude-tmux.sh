#!/usr/bin/env bash
# Claude Code -> tmux state painter. Claude Code hooks call this to record each
# Claude pane's state; the tmux status bar and pane borders render it. Pane
# navigation (jump / fzf switchers) lives in scripts/pane-switch.sh.
#
#   claude-tmux.sh state busy|done|wait|clear   # (hooks) paint THIS pane's state
#
# State is per-PANE, so several Claude sessions can share one window: each pane's
# @claude_state user option is the source of truth (shown on its pane border). The
# script also derives a per-WINDOW @claude_win = the highest-priority state
# (wait > busy > done) across the window's claude panes, which the status bar
# renders as a single glyph. No-ops outside tmux.
#
# Hooks drive every transition: UserPromptSubmit->busy, PostToolUse->busy,
# Stop/StopFailure->done, Notification[permission_prompt]->wait,
# Notification[idle_prompt]->done, SessionStart->done, SessionEnd->clear.
#  - 'wait' (red) means ONLY one thing: blocked on a permission prompt, awaiting your
#    input. PostToolUse->busy is what brings a pane back to 'busy' the moment you
#    approve and work resumes — no other hook fires then, so without it the pane would
#    stay red while Claude works on. (cmd_state no-ops when unchanged, so the per-tool
#    hook is essentially free.)
#  - Notification[idle_prompt] fires when the input sits idle ~60s AFTER a turn ends,
#    i.e. the pane is finished, not blocked on you — so it maps to 'done', not 'wait'.
#    Bonus: this auto-clears a pane left stuck on 'busy' by an Esc-interrupt once it idles.
#  - StopFailure matters because a turn killed by an API/overload/rate-limit error fires
#    it INSTEAD of Stop, so without it a failed turn would stay stuck on 'busy'.
# KNOWN LIMITATION: pressing Esc to interrupt fires no hook at all, so an interrupted
# pane reads 'busy' until either its next completed turn re-paints it OR idle_prompt
# fires (~60s) and marks it done. Claude Code exposes no interrupt/cancel hook.
set -u

in_tmux() { [ -n "${TMUX:-}" ]; }

# recompute the window-level aggregate for the window owning $TMUX_PANE, reducing
# over its claude panes by priority: wait > busy > done (none -> unset @claude_win).
_recompute_win() {
  local win="" wid best="" cmd st
  # list-panes -t <pane-id> with neither -a nor -s lists every pane in that pane's
  # window and yields #{window_id} per row (identical on each), so the window id falls
  # out of the loop for free — no separate display-message to resolve it. Capture it
  # into $win INSIDE the body: reading straight into $win would lose it, because the
  # loop's final (EOF) read clears its target vars, leaving $win empty afterwards —
  # which made the [ -n "$win" ] guard below always bail and @claude_win never update.
  while read -r wid cmd st; do
    win=$wid
    [ "$cmd" = claude ] || continue   # claude = process name marking a Claude pane
    case "$st" in
      wait) best=wait; break ;;
      busy) [ "$best" != wait ] && best=busy ;;
      done) [ -z "$best" ] && best=done ;;
    esac
  done < <(tmux list-panes -t "$TMUX_PANE" -F '#{window_id} #{pane_current_command} #{@claude_state}')
  [ -n "$win" ] || return 0
  if [ -n "$best" ]; then
    tmux set-option -w -t "$win" @claude_win "$best"
  else
    tmux set-option -uw -t "$win" @claude_win
  fi
}

# state <busy|done|wait|clear> — paint the pane $TMUX_PANE (set by the calling hook,
# so it always targets the exact Claude session that fired the hook).
cmd_state() {
  in_tmux || exit 0
  [ -n "${TMUX_PANE:-}" ] || exit 0
  local new=${1:-clear} cur
  cur=$(tmux show-options -pqv -t "$TMUX_PANE" @claude_state 2>/dev/null)
  # Idempotent: if the pane is already in the requested state there is nothing to
  # repaint, so skip the set, the window recompute and the client refresh. This keeps
  # the per-tool PostToolUse->busy hook essentially free — after the first tool the
  # pane is already 'busy', so every later tool in the turn is a no-op — and avoids a
  # status-bar redraw storm on tool-heavy turns.
  case "$new" in
    busy|done|wait)
      [ "$cur" = "$new" ] && exit 0
      tmux set-option -p -t "$TMUX_PANE" @claude_state "$new" ;;
    clear)
      [ -z "$cur" ] && exit 0
      tmux set-option -up -t "$TMUX_PANE" @claude_state ;;
    *) exit 0 ;;
  esac
  _recompute_win
  # force an immediate status redraw on every attached client (otherwise the glyph
  # only refreshes on the next status-interval tick, up to 15s later)
  tmux list-clients -F '#{client_name}' 2>/dev/null | while IFS= read -r c; do
    tmux refresh-client -S -t "$c" 2>/dev/null || true
  done
}

sub=${1:-}; shift || true
case "$sub" in
  state)  cmd_state "${1:-}" ;;
  *) echo "usage: claude-tmux.sh {state busy|done|wait|clear}" >&2; exit 2 ;;
esac
