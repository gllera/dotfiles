#------- Toggles -------#
def toggle-highlighter -params 2.. %{
    try %{
        add-highlighter %arg{@}
        echo -markup "{green}add-highlighter %arg{@}{Default}"
    } catch %{
        remove-highlighter %arg{1}
        echo -markup "{red}remove-highlighter %arg{1}{Default}"
    }
}

