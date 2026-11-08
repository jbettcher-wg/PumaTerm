#!/bin/sh
# Run a test build of PumaTerm in the console user's session behind other
# windows, type a test line into it, and dump its own frame to
# /tmp/pumaterm-frame.png (and the composited window to
# /tmp/pumaterm-window.png).
#
# The test copy runs from /tmp/PumaTermTest.app, never /Applications, and
# only processes running from that path are killed: the user's own
# PumaTerm windows are left alone.
#
# Usage, as root on the Mac (over ssh is the point): put build/PumaTerm.app
# in /tmp/PumaTerm.app.tgz and the text to type in /tmp/pumatermtest.input,
# then `WAIT=8 sh pumatermtest.sh`. TEST_USER is the console user by default.
APP=/tmp/PumaTermTest.app
TEST_USER=${TEST_USER:-$(stat -f %Su /dev/console)}
testpids() { ps -axo pid=,comm= | awk -v p="$APP/Contents/MacOS/pumaterm" '$2 == p {print $1}'; }
for p in $(testpids); do kill $p; done
sleep 1
rm -rf $APP /tmp/ptt.$$ && mkdir /tmp/ptt.$$ && tar xzf /tmp/PumaTerm.app.tgz -C /tmp/ptt.$$ && \
	mv /tmp/ptt.$$/PumaTerm.app $APP && rmdir /tmp/ptt.$$ && chown -R $TEST_USER $APP
rm -f /tmp/pumaterm-frame.png /tmp/pumaterm-window.png
FINDER=$(ps -axo pid=,user=,comm= | awk -v u="$TEST_USER" '$2==u && $3 ~ /Finder$/ {print $1}' | head -1)
INPUT=$(cat /tmp/pumatermtest.input)
launchctl bsexec "$FINDER" sudo -u $TEST_USER -H env PUMATERM_STARTUP_INPUT="$INPUT" \
	PUMATERM_TEST_SELECT="$PUMATERM_TEST_SELECT" PUMATERM_TEST_WINDOWS="$PUMATERM_TEST_WINDOWS" \
	PUMATERM_TEST_TABS="$PUMATERM_TEST_TABS" PUMATERM_TEST_PREFS="$PUMATERM_TEST_PREFS" \
	PUMATERM_TEST_LIVE="$PUMATERM_TEST_LIVE" PUMATERM_TEST_FOCUS="$PUMATERM_TEST_FOCUS" PUMATERM_NO_GL="$PUMATERM_NO_GL" PUMATERM_TEST_ABOUT="$PUMATERM_TEST_ABOUT" PUMATERM_TEST_CLOSE="$PUMATERM_TEST_CLOSE" PUMATERM_TEST_BLUR="$PUMATERM_TEST_BLUR" \
	$APP/Contents/MacOS/pumaterm $PUMATERM_ARGS > /tmp/pumaterm.out 2>&1 &
sleep ${WAIT:-6}
P=$(testpids | head -1)
echo "test pid: ${P:-none}"
[ -n "$P" ] && kill -USR1 $P
sleep 2
ls -la /tmp/pumaterm-frame.png 2>&1
tail -3 /tmp/pumaterm.out
[ -n "$KEEP" ] || for p in $(testpids); do kill $p; done
