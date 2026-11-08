#!/bin/sh
# Build the drag-to-install disk image: PumaTerm.app, an Applications alias,
# a background with an arrow between them, PumaTerm's icon on the volume.
#
#   make && tools/make-dmg.sh        # -> build/PumaTerm-<version>.dmg
#
# Run it as the logged-in user, in the window server session: Finder lays the
# window out (icon positions and the background are stored in the image's
# .DS_Store, which only Finder writes), so a Finder window opens and closes
# while it runs. From ssh, wrap it in `launchctl bsexec <Finder pid> sudo -u
# <user>`. Uses only what 10.5 ships: hdiutil, osascript, SetFile.
set -e
cd "$(dirname "$0")/.."
APP=${1:-build/PumaTerm.app}
VER=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
VOL=PumaTerm
STAGE=build/dmg
RW=build/PumaTerm-rw.dmg
OUT=build/PumaTerm-$VER.dmg

rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp tools/dmg-background.png "$STAGE/.background/background.png"
cp icon/PumaTerm.icns "$STAGE/.VolumeIcon.icns"

hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size 20m "$RW"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"
SetFile -a C "/Volumes/$VOL"			# use .VolumeIcon.icns
SetFile -a V "/Volumes/$VOL/.background"	# keep it hidden

# Window bounds are the frame; the content is 540 x 380, the background's size.
osascript <<OSA
tell application "Finder"
	tell disk "$VOL"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 740, 500}
		set opts to the icon view options of container window
		set arrangement of opts to not arranged
		set icon size of opts to 112
		set text size of opts to 12
		set background picture of opts to file ".background:background.png"
		set position of item "PumaTerm.app" of container window to {140, 175}
		set position of item "Applications" of container window to {400, 175}
		update without registering applications
		delay 2
		close
	end tell
end tell
OSA
rm -rf "/Volumes/$VOL/.fseventsd"	# the mount's own, not the product's
sync
hdiutil detach -quiet "/Volumes/$VOL"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -f "$RW"
rm -rf "$STAGE"
ls -la "$OUT"
