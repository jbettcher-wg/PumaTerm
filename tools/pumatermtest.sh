#!/bin/sh
# Run a test build of PumaTerm in the console user's session behind other
# windows, type a test line into it, and dump its own frame to
# /tmp/pumaterm-frame.png (and the composited window to
# /tmp/pumaterm-window.png).
#
# The test copy runs from /tmp/PumaTermTest.app, never /Applications, and
# only processes running from that path are killed: the user's own
# PumaTerm windows are left alone. (Until 2026-11-08 this killed every
# pumaterm process, which closed the user's sessions.)
APP=/tmp/PumaTermTest.app
testpids() { ps -axo pid=,comm= | awk -v p="$APP/Contents/MacOS/pumaterm" '$2 == p {print $1}'; }
for p in $(testpids); do kill $p; done
sleep 1
rm -rf $APP /tmp/ptt.$$ && mkdir /tmp/ptt.$$ && tar xzf /tmp/PumaTerm.app.tgz -C /tmp/ptt.$$ && \
	mv /tmp/ptt.$$/PumaTerm.app $APP && rmdir /tmp/ptt.$$ && chown -R jbettcher:admin $APP
rm -f /tmp/pumaterm-frame.png /tmp/pumaterm-window.png
FINDER=$(ps -axo pid=,user=,comm= | awk '$2=="jbettcher" && $3 ~ /Finder$/ {print $1}' | head -1)
INPUT=$(cat /tmp/pumatermtest.input)
launchctl bsexec "$FINDER" sudo -u jbettcher -H env PUMATERM_STARTUP_INPUT="$INPUT" \
	PUMATERM_TEST_SELECT="$PUMATERM_TEST_SELECT" PUMATERM_TEST_WINDOWS="$PUMATERM_TEST_WINDOWS" \
	PUMATERM_TEST_TABS="$PUMATERM_TEST_TABS" PUMATERM_TEST_PREFS="$PUMATERM_TEST_PREFS" \
	PUMATERM_TEST_LIVE="$PUMATERM_TEST_LIVE" \
	$APP/Contents/MacOS/pumaterm $PUMATERM_ARGS > /tmp/pumaterm.out 2>&1 &
sleep ${WAIT:-6}
P=$(testpids | head -1)
echo "test pid: ${P:-none}"
[ -n "$P" ] && kill -USR1 $P
sleep 2
ls -la /tmp/pumaterm-frame.png 2>&1
tail -3 /tmp/pumaterm.out
[ -n "$KEEP" ] || for p in $(testpids); do kill $p; done
