local awful = require("awful")
local naughty = require("naughty")
local wibox = require("wibox")

local NotifyVol

function fRofi()
    awful.util.spawn("rofi -show run", false)
end

function fWiboxH ()
    local scr = awful.screen.focused()
    scr.mywibox.visible = not scr.mywibox.visible
end

function fSetVol(a, s)
  os.execute( string.format( "amixer sset Master %s%%", a ))

  naughty.destroy( NotifyVol )

  NotifyVol = naughty.notify( { text = "Vol: " .. s } )
end

function useless_gaps_resize(amount)
    local scr = awful.screen.focused()
    local d = dpi(amount)

    for key, tag in pairs(scr.tags) do
        tag.gap = tag.gap + d
    end

    awful.layout.arrange(scr)
end

function useless_margin_resize(amount)
    local scr = awful.screen.focused()
    local d = dpi(amount)

    if scr.padding.left + d >= 0 then
        scr.padding = {
            left   = scr.padding.left + d,
            right  = scr.padding.right + d,
            top    = scr.padding.top + d,
            bottom = scr.padding.bottom + d
        }
    end
end

temp_widget = awful.widget.watch( 'status_oneliner', 15)
