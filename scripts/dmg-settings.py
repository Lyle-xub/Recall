"""Finder layout for the Recall installer. Loaded by dmgbuild; no Finder scripting."""
import os

application = os.path.abspath(defines['app'])
artwork = os.path.abspath(defines['artwork'])
format = 'ULFO'
files = [application]
symlinks = {'Applications': '/Applications'}
icon = os.path.join(artwork, 'Recall.icns')
background = os.path.join(artwork, 'Installer-background.tiff')
hide_extension = ['Recall.app']
icon_locations = {'Recall.app': (190, 220), 'Applications': (530, 220)}
window_rect = ((160, 120), (720, 440))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
default_view = 'icon-view'
include_icon_view_settings = True
include_list_view_settings = False
show_icon_preview = False
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = 'bottom'
text_size = 13
icon_size = 100
