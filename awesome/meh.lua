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
    local x = dpi(amount)

    for key, tag in pairs(scr.tags) do
        tag.gap = tag.gap + x
    end

    awful.layout.arrange(scr)
end

function useless_margin_resize(amount)
    local scr = awful.screen.focused()
    local x = scr.padding.left + dpi(amount)

    if x >= 0 then
        scr.padding = { left = x, right = x, top = x, bottom = x }
    end
end

temp_widget = awful.widget.watch( 'status_oneliner', 15)
