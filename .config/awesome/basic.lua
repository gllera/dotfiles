local naughty = require("naughty")
local awful = require("awful")

-- {{{ Error handling
-- Check if awesome encountered an error during startup and fell back to
-- another config (This code will only ever execute for the fallback config)
if awesome.startup_errors then
    naughty.notify({ preset = naughty.config.presets.critical,
                     title = "Oops, there were errors during startup!",
                     text = awesome.startup_errors })
end

-- Handle runtime errors after startup
do
    local in_error = false
    awesome.connect_signal("debug::error", function (err)
        -- Make sure we don't go into an endless error loop
        if in_error then return end
        in_error = true

        naughty.notify({ preset = naughty.config.presets.critical,
                         title = "Oops, an error happened!",
                         text = tostring(err) })
        in_error = false
    end)
end
-- }}}

-- {{{ Signals
-- Signal function to execute when a new client appears.
client.connect_signal("manage", function (c)
    -- Set the windows at the slave,
    -- i.e. put it at the end of others instead of setting it master.
    -- if not awesome.startup then awful.client.setslave(c) end

    if awesome.startup
      and not c.size_hints.user_position
      and not c.size_hints.program_position then
        -- Prevent clients from being unreachable after screen count changes.
        awful.placement.no_offscreen(c)
    end
end)

-- Enable sloppy focus, so that focus follows mouse.
client.connect_signal( "mouse::enter", function(c) c:emit_signal( "request::activate", "mouse_enter", {raise = false} ) end )
-- }}}

function fPrev()
    awful.client.focus.history.previous()
    if client.focus then
        client.focus:raise()
    end
end

function fFullS(c)
    c.fullscreen = not c.fullscreen
    c:raise()
end

function fMaxm(c)
    c.maximized = not c.maximized
    c:raise()
end 

function fTagOnly(i) return function()
    local tag = awful.screen.focused().tags[i]
    if tag then
        tag:view_only()
    end
end end

function fTagDisplay(i) return function()
    local tag = awful.screen.focused().tags[i]
    if tag then
        awful.tag.viewtoggle(tag)
    end
end end

function fClientMove(i) return function()
    if client.focus then
        local tag = client.focus.screen.tags[i]
        if tag then
            client.focus:move_to_tag(tag)
        end
    end
end end

function fClientTagToggle(i) return function()
    if client.focus then
        local tag = client.focus.screen.tags[i]
        if tag then
            client.focus:toggle_tag(tag)
        end
    end
end end
