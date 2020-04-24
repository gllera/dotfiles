[[ -f ~/.config/Xresources ]] && xrdb -merge -I$HOME ~/.config/Xresources
[[ -f ~/.config/Xmodmap    ]] && xmodmap             ~/.config/Xmodmap

urxvtd -q -f -o &

i3
#awesome
