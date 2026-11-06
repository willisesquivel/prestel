# dmgbuild settings. Run through make-dmg.sh, which passes:
#   -D app=/path/Prestel.app -D background=/path/background.tiff -D layout_dir=/path/scripts/dmg
import os.path
import sys

sys.path.insert(0, defines["layout_dir"])
from layout import APP, APPS, HEIGHT, ICON, WIDTH  # noqa: E402

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "Prestel.icns")

background = defines["background"]
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((240, 180), (WIDTH, HEIGHT))
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = ICON
icon_locations = {app_name: APP, "Applications": APPS}
