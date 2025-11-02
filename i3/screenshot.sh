#!/bin/bash

[[ "$1" == "-r" ]] &&
    OPTS="-s -b 2 -c 0.35,0.55,0.85,0.25 -l" ||
    printf -v OPTS -- '-i %d' `xprop -root _NET_ACTIVE_WINDOW | awk '{print $5}'`

maim -u -f png $OPTS |
    tee "$HOME/screenshot-$(date +%FT%T).png" |
    xclip -selection clipboard -t image/png
