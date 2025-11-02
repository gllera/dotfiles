#!/bin/bash

PID=$(notify-send -epu critical "System mode [ENABLED]")
NOTIFY="notify-send -er $PID"
trap "$NOTIFY -t 1000 'System mode [DISABLED]'" exit

DMENU=(timeout 20s dmenu -i -sb '#8B0000' -sf '#FFD700')
RES=$(printf '%s\n' suspend reboot poweroff reload.i3 restart.i3 exit.i3 | "${DMENU[@]}" -p System)

[[ -n $RES ]] || exit
printf '%s\n' No Yes | "${DMENU[@]}" -p "(confirm) $RES" | grep -q Yes >/dev/null || exit

case "$RES" in
  suspend)    systemctl suspend     ;;
  reboot)     systemctl reboot      ;;
  poweroff)   systemctl poweroff -i ;;
  exit.i3)    i3-msg exit ;;
  reload.i3)
    i3-msg reload
    trap - exit
    $NOTIFY -t 2500 -u low "$RES [DONE]"
  ;;
  restart.i3)
    i3-msg restart
    trap - exit
    $NOTIFY -t 2500 -u low "$RES [DONE]"
  ;;
esac
