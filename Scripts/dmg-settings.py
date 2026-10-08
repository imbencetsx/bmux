import os

files = [os.path.abspath("[bmux].app")]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
window_rect = ((200, 200), (900, 422))
icon_locations = {"[bmux].app": (300, 205), "Applications": (600, 205)}
icon_size = 96
# Captions are drawn in Geist Mono on the background; native names remain
# available to Finder accessibility without duplicating the visible captions.
text_size = 10
label_pos = "right"
show_icon_preview = True
show_toolbar = False
show_status_bar = False
show_sidebar = False
show_tab_view = False
show_pathbar = False
default_view = "icon-view"
