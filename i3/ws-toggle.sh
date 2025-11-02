#!/bin/bash
# toggle workspace pairs: 1↔5, 2↔6, 3↔7, etc.

case $(i3-msg -t get_workspaces | jq '.[] | select(.focused==true).num') in
    1) W=5 ;;
    2) W=6 ;;
    3) W=7 ;;
    4) W=8 ;;
    5) W=1 ;;
    6) W=2 ;;
    7) W=3 ;;
    8) W=4 ;;
    9) W=10 ;;
    10) W=9 ;;
    *) W=1 ;;
esac

if [[ $1 == "-m" ]]; then
    i3-msg "move workspace $W"
else
    i3-msg "workspace $W"
fi
