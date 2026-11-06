#!/bin/zsh
# Builds a styled Prestel DMG from a built Prestel.app without opening Finder.
# Usage: scripts/dmg/make-dmg.sh /path/to/Prestel.app /path/to/output.dmg
# To also notarize and staple, store Apple notary credentials once with
# `xcrun notarytool store-credentials notary ...` then run:
#   PRESTEL_NOTARY_PROFILE=notary scripts/dmg/make-dmg.sh Prestel.app out.dmg
# When the Sparkle tools are installed (sign_update on PATH, or under
# ~/.sparkle-tools/bin, or PRESTEL_SIGN_UPDATE=/path/to/sign_update), the DMG
# is also signed for Sparkle updates and appended to appcast.xml.
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

sign_update=${PRESTEL_SIGN_UPDATE:-$(command -v sign_update || echo "$HOME/.sparkle-tools/bin/sign_update")}
appcast=$here/../../appcast.xml
if [[ -x $sign_update && -f $appcast ]]; then
  version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
  siginfo=$("$sign_update" "$out")
  sig=$(echo "$siginfo" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
  len=$(echo "$siginfo" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')
  pubdate=$(date -u "+%a, %d %b %Y %H:%M:%S %z")
  item="    <item>
      <title>Prestel $version</title>
      <link>https://github.com/willisesquivel/prestel/releases/tag/v$version</link>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <pubDate>$pubdate</pubDate>
      <enclosure url=\"https://github.com/willisesquivel/prestel/releases/download/v$version/Prestel-$version.dmg\" sparkle:edSignature=\"$sig\" length=\"$len\" type=\"application/octet-stream\"/>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
    </item>"
  python3 - "$appcast" "$item" <<'PY'
import sys
path, item = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace('</channel>', item + '\n  </channel>', 1)
open(path, 'w').write(s)
PY
  echo "appcast.xml: added $version (commit it with the release)"
else
  echo "note: sign_update not found, skipping Sparkle appcast update" >&2
fi
echo "$out"
