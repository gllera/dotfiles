#!/bin/bash

ROFI=(timeout 20s rofi -dmenu -theme-str 'window {width: 20ch;}' )
RES=$(printf '%s\n' suspend reboot poweroff i3-reload i3-restart i3-exit | "${ROFI[@]}" -p System)

[[ -n $RES ]] || exit
printf '%s\n' No Yes | "${ROFI[@]}" -p "$RES?" | grep -q Yes >/dev/null || exit

case "$RES" in
  suspend)  systemctl suspend     ;;
  reboot)   systemctl reboot      ;;
  poweroff) systemctl poweroff -i ;;
  i3-reload)  i3-msg reload;  notify-send -eu low "i3 configuration reloaded" ;;
  i3-restart) i3-msg restart; notify-send -eu low "i3 restarted"              ;;
  i3-exit)    i3-msg exit ;;
esac
