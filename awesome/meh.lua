local awful = require("awful")
local naughty = require("naughty")
local wibox = require("wibox")

local NotifyVol

function fRofi()
    awful.util.spawn("rofi -show run", false)
end

function fWiboxH ()
    for s in screen do
        s.mywibox.visible = not s.mywibox.visible
    end
end

function fSetVol(a, s)
  os.execute( string.format( "amixer sset PCM %s%%", a ))

  naughty.destroy( NotifyVol )
  NotifyVol = naughty.notify( { text = "Vol: " .. s } )
end

temp_widget = awful.widget.watch( 'status_oneliner', 15)
