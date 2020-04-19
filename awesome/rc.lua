-- Standard awesome library
local gears = require("gears")
local awful = require("awful")
local wibox = require("wibox")
local naughty = require("naughty")
local menubar = require("menubar")
local beautiful = require("beautiful")
local hotkeys_popup = require("awful.hotkeys_popup")

require("awful.autofocus")
require("basic")

dpi = beautiful.xresources.apply_dpi
beautiful.init( gears.filesystem.get_configuration_dir() .. "theme.lua")
theme = beautiful

client.connect_signal( "focus",        function(c) c.border_color = beautiful.border_focus end )
client.connect_signal( "unfocus",      function(c) c.border_color = beautiful.border_normal end )

require("meh")

terminal = os.getenv("TERMINAL") or "urxvtc"
browser  = os.getenv("BROWSER")  or "google-chrome-stable"
editor   = os.getenv("EDITOR")   or "code"

MOD = "Mod4"

-- Table of layouts to cover with awful.layout.inc, order matters.
awful.layout.layouts = {
    awful.layout.suit.spiral.dwindle,
    awful.layout.suit.tile,
    awful.layout.suit.fair,
    awful.layout.suit.fair.horizontal,
--    awful.layout.suit.floating,
--    awful.layout.suit.spiral,
--    awful.layout.suit.max,
--    awful.layout.suit.max.fullscreen,
--    awful.layout.suit.magnifier,
}
-- }}}

-- {{{ Wibar
local function set_wallpaper(s)
    -- Wallpaper
    if theme.wallpaper then
        local wallpaper = theme.wallpaper

        -- If wallpaper is a function, call it with the screen
        if type(wallpaper) == "function" then
            wallpaper = wallpaper(s)
        end
        gears.wallpaper.maximized(wallpaper, s, true)
    end
end

-- Re-set wallpaper when a screen's geometry changes (e.g. different resolution)
screen.connect_signal("property::geometry", set_wallpaper)

awful.screen.connect_for_each_screen(function(s)
    -- Wallpaper
    set_wallpaper(s)

    -- Each screen has its own tag table.
    awful.tag({ "1", "2", "3", "4", "5" }, s, awful.layout.layouts[1])

    -- Create a promptbox for each screen
    s.mypromptbox = awful.widget.prompt()
    -- Create a taglist widget
    s.mytaglist = awful.widget.taglist {
        screen  = s,
        filter  = awful.widget.taglist.filter.noempty,
        buttons = taglist_buttons
    }

    -- Create the wibox
    s.mywibox = awful.wibar({ position = "top", screen = s })

    -- Add widgets to the wibox
    s.mywibox:setup {
        layout = wibox.layout.align.horizontal,
        { -- Left widgets
            layout = wibox.layout.fixed.horizontal,
            s.mytaglist,
            s.mypromptbox,
        },
	nil,
        { -- Right widgets
            layout = wibox.layout.fixed.horizontal,
            wibox.widget.systray(),
	    temp_widget,
        },
    }

    s.mywibox.visible = false
end)
-- }}}

-- {{{ Key bindings
globalkeys = gears.table.join(
    awful.key( { MOD            }, "s",                  hotkeys_popup.show_help,                 { group = "awesome",  description = "show help" } ),
    awful.key( { MOD, "Control" }, "r",                  awesome.restart,                         { group = "awesome",  description = "reload awesome" } ),
    awful.key( { MOD, "Shift"   }, "q",                  awesome.quit,                            { group = "awesome",  description = "quit awesome" } ),
    awful.key( { MOD, "Control" }, "s",     function ()  awful.util.spawn("xrandr -s 0")     end, { group = "system",  description = "reset screens" } ),
    awful.key( { MOD,           }, "6",     function ()  fSetVol("0",   "0")                 end, { group = "system",  description = "set volumen 0%" } ),
    awful.key( { MOD,           }, "7",     function ()  fSetVol("60", "25")                 end, { group = "system",  description = "set volumen 25%" } ),
    awful.key( { MOD,           }, "8",     function ()  fSetVol("70", "50")                 end, { group = "system",  description = "set volumen 50%" } ),
    awful.key( { MOD,           }, "9",     function ()  fSetVol("80", "75")                 end, { group = "system",  description = "set volumen 75%" } ),
    awful.key( { MOD,           }, "0",     function ()  fSetVol("90","100")                 end, { group = "system",  description = "set volumen 100%" } ),
    awful.key( { MOD,           }, "Left",               awful.tag.viewprev,                      { group = "tag",      description = "view previous" } ),
    awful.key( { MOD,           }, "Right",              awful.tag.viewnext,                      { group = "tag",      description = "view next" } ),
    awful.key( { MOD,           }, "Escape",             awful.tag.history.restore,               { group = "tag",      description = "go back" } ),
    awful.key( { MOD,           }, "Return", function () awful.spawn(terminal)               end, { group = "launcher", description = "run terminal" } ),
    awful.key( { MOD,           }, "w",      function () awful.spawn(browser)                end, { group = "launcher", description = "run browser" } ),
    awful.key( { MOD,           }, "e",      function () awful.spawn(editor)                 end, { group = "launcher", description = "run editor" } ),
    awful.key( { MOD,           }, "r",                  fRofi,                                   { group = "launcher", description = "run" } ),
    awful.key( { MOD,           }, "p",      function () menubar.show()                      end, { group = "launcher", description = "show the menubar" } ),
    awful.key( { MOD,           }, "j",      function () awful.client.focus.byidx( 1)      end, { group = "client", description = "focus next by index" } ),
    awful.key( { MOD,           }, "k",      function () awful.client.focus.byidx(-1)      end, { group = "client", description = "focus previous by index" } ),
    awful.key( { MOD, "Shift"   }, "j",      function () awful.client.swap.byidx( 1)       end, { group = "client", description = "swap with next client by index" } ),
    awful.key( { MOD, "Shift"   }, "k",      function () awful.client.swap.byidx(-1)       end, { group = "client", description = "swap with previous client by index" } ),
    awful.key( { MOD, "Control" }, "j",      function () awful.screen.focus_relative( 1)   end, { group = "screen", description = "focus the next screen" } ),
    awful.key( { MOD, "Control" }, "k",      function () awful.screen.focus_relative(-1)   end, { group = "screen", description = "focus the previous screen" } ),
    -- Standard program
    awful.key( { MOD,           }, "[",      function () useless_gaps_resize(-3)             end, {description = "increment useless gaps", group = "tag"}),
    awful.key( { MOD,           }, "]",      function () useless_gaps_resize( 3)              end, {description = "decrement useless gaps", group = "tag"}),
    awful.key( { MOD, "Control" }, "[",      function () useless_margin_resize(-3)           end, {description = "increment useless margins", group = "tag"}),
    awful.key( { MOD, "Control" }, "]",      function () useless_margin_resize( 3)            end, {description = "decrement useless margins", group = "tag"}),
    awful.key( { MOD,           }, "l",      function () awful.tag.incmwfact( 0.05)          end, { group = "layout", description = "increase master width factor" } ),
    awful.key( { MOD,           }, "h",      function () awful.tag.incmwfact(-0.05)          end, { group = "layout", description = "decrease master width factor" } ),
    awful.key( { MOD, "Shift"   }, "h",      function () awful.tag.incnmaster( 1, nil, true) end, { group = "layout", description = "increase the number of master clients" } ),
    awful.key( { MOD, "Shift"   }, "l",      function () awful.tag.incnmaster(-1, nil, true) end, { group = "layout", description = "decrease the number of master clients" } ),
    awful.key( { MOD, "Control" }, "h",      function () awful.tag.incncol( 1, nil, true)    end, { group = "layout", description = "increase the number of columns" } ),
    awful.key( { MOD, "Control" }, "l",      function () awful.tag.incncol(-1, nil, true)    end, { group = "layout", description = "decrease the number of columns" } ),
    awful.key( { MOD,           }, "space",  function () awful.layout.inc( 1)                end, { group = "layout", description = "select next" } ),
    awful.key( { MOD, "Shift"   }, "space",  function () awful.layout.inc(-1)                end, { group = "layout", description = "select previous" } ),
    awful.key( { MOD,           }, "b",                  fWiboxH,                                 { group = "layout", description = "show/hide top bar" } ),
    awful.key( { MOD,           }, "u",                  awful.client.urgent.jumpto,              { group = "client", description = "jump to urgent client" } ),
    awful.key( { MOD,           }, "Tab",                fPrev,                                   { group = "client", description = "go back" } )
)

for i = 1, 5 do
    globalkeys = gears.table.join(
        globalkeys,
        awful.key( { MOD,                    }, "#" .. i + 9, fTagOnly(i),         { group = "tag", description = "view tag #" .. i } ),
        awful.key( { MOD, "Control"          }, "#" .. i + 9, fTagDisplay(i),      { group = "tag", description = "toggle tag #" .. i } ),
        awful.key( { MOD, "Control", "Shift" }, "#" .. i + 9, fClientTagToggle(i), { group = "tag", description = "toggle focused client on tag #" .. i } ),
        awful.key( { MOD, "Shift"            }, "#" .. i + 9, fClientMove(i),      { group = "tag", description = "move focused client to tag #" .. i } )
    )
end

clientkeys = gears.table.join(
    awful.key( { MOD,           }, "f",                   fFullS,                               { group = "client", description = "toggle fullscreen" } ),
    awful.key( { MOD,           }, "m",                   fMaxm,                                { group = "client", description = "(un)maximize" } ),
    awful.key( { MOD, "Shift"   }, "c",      function (c) c:kill()                         end, { group = "client", description = "close" } ),
    awful.key( { MOD, "Control" }, "space",               awful.client.floating.toggle,         { group = "client", description = "toggle floating" } ),
    awful.key( { MOD, "Control" }, "Return", function (c) c:swap(awful.client.getmaster()) end, { group = "client", description = "move to master" } ),
    awful.key( { MOD,           }, "o",      function (c) c:move_to_screen()               end, { group = "client", description = "move to screen" } ),
    awful.key( { MOD,           }, "t",      function (c) c.ontop = not c.ontop            end, { group = "client", description = "toggle keep on top" } )
)


clientbuttons = gears.table.join(
    awful.button( {        }, 1, function (c) c:emit_signal( "request::activate", "mouse_click", { raise = true } )                              end ),
    awful.button( { MOD }, 1, function (c) c:emit_signal( "request::activate", "mouse_click", { raise = true } ) awful.mouse.client.move(c)   end ),
    awful.button( { MOD }, 3, function (c) c:emit_signal( "request::activate", "mouse_click", { raise = true } ) awful.mouse.client.resize(c) end )
)

-- Set keys
root.keys(globalkeys)
-- }}}

-- {{{ Rules
-- Rules to apply to new clients (through the "manage" signal).
awful.rules.rules = {
    -- All clients will match this rule.
    { rule = { },
      properties = { border_width = theme.border_width,
                     border_color = theme.border_normal,
                     focus = awful.client.focus.filter,
                     raise = true,
                     keys = clientkeys,
                     buttons = clientbuttons,
                     screen = awful.screen.preferred,
                     placement = awful.placement.no_overlap + awful.placement.no_offscreen
     }
    },

    -- Floating clients.
    { rule_any = {
        instance = {
          "copyq",  -- Includes session name in class.
          "pinentry",
        },
        class = {
          "Arandr",
          "Blueman-manager",
          "Gpick",
          "Kruler",
          "MessageWin",  -- kalarm.
          "Sxiv",
          "Wpa_gui",
          "veromix",
          "xtightvncviewer"},

        -- Note that the name property shown in xprop might be set slightly after creation of the client
        -- and the name shown there might not match defined rules here.
        name = {
          "Event Tester",  -- xev.
        },
        role = {
          "pop-up",         -- e.g. Google Chrome's (detached) Developer Tools.
        }
      }, properties = { floating = true }},
}
-- }}}
