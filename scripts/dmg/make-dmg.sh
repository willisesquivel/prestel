#!/bin/zsh
# Builds a styled Prestel DMG from a built Prestel.app without opening Finder.
# Usage: scripts/dmg/make-dmg.sh /path/to/Prestel.app /path/to/output.dmg
# To also notarize and staple, store Apple notary credentials once with
# `xcrun notarytool store-credentials notary ...` then run:
#   PRESTEL_NOTARY_PROFILE=notary scripts/dmg/make-dmg.sh Prestel.app out.dmg
set -euo pipefail
here=${0:A:h}
app=${1:?path to Prestel.app}
out=${2:?output .dmg path}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

venv=${PRESTEL_DMG_VENV:-$HOME/.cache/prestel-dmg-venv}
if [[ ! -x $venv/bin/dmgbuild ]]; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install -q dmgbuild pillow
fi

"$venv/bin/python" -I "$here/background.py" "$work"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff" >/dev/null
rm -f "$out"
"$venv/bin/dmgbuild" -s "$here/settings.py" \
  -D app="$app" -D background="$work/background.tiff" -D layout_dir="$here" \
  Prestel "$out"
hdiutil verify "$out" >/dev/null
if [[ -n ${PRESTEL_NOTARY_PROFILE:-} ]]; then
  xcrun notarytool submit "$out" --keychain-profile "$PRESTEL_NOTARY_PROFILE" --wait
  xcrun stapler staple "$out"
fi
echo "$out"
