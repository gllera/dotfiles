#!/usr/bin/env bash
# Badge palette for the Claude usage badge (claude-usage.sh), sourced via:
#     HERE="${0%/*}"; . "$HERE/config.sh"
# Truecolor; terminal-features RGB is set in tmux.conf.
CU_PILL='#3a2c10'    # pill background (dark amber)
CU_TIME='#bfa06a'    # reset countdowns (dim amber)
CU_SEP='#7a5e28'     # dot separators
# Percentage color by load, and the thresholds (%) at which it escalates.
CU_GREEN=colour40    # below the amber threshold
CU_AMBER=colour208   # orange — pops on the amber pill
CU_RED=colour196
CU_AMBER_AT=50
CU_RED_AT=80
