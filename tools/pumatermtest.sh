#!/bin/sh
# Run PumaTerm in the console user's session behind other windows, type a test
# line into it, and dump its own frame to /tmp/pumaterm-frame.png.
# Processes are matched by executable name (ps comm), never by command line,
# so this script cannot match itself.
termpids() { ps -axo pid=,comm= | awk '$2 ~ /MacOS\/pumaterm$/ {print $1}'; }
for p in $(termpids); do kill $p; done
sleep 1
cd /Applications && rm -rf PumaTerm.app && tar xzf /tmp/PumaTerm.app.tgz 2>/dev/null && chown -R jbettcher:admin PumaTerm.app
rm -f /tmp/pumaterm-frame.png
FINDER=$(ps -axo pid=,user=,comm= | awk '$2=="jbettcher" && $3 ~ /Finder$/ {print $1}' | head -1)
INPUT=$(cat /tmp/pumatermtest.input)
launchctl bsexec "$FINDER" sudo -u jbettcher -H env PUMATERM_STARTUP_INPUT="$INPUT" PUMATERM_TEST_SELECT="$PUMATERM_TEST_SELECT" PUMATERM_TEST_WINDOWS="$PUMATERM_TEST_WINDOWS" PUMATERM_TEST_TABS="$PUMATERM_TEST_TABS" \
	/Applications/PumaTerm.app/Contents/MacOS/pumaterm $PUMATERM_ARGS > /tmp/pumaterm.out 2>&1 &
sleep ${WAIT:-6}
P=$(termpids | head -1)
echo "term pid: ${P:-none}"
[ -n "$P" ] && kill -USR1 $P
sleep 2
ls -la /tmp/pumaterm-frame.png 2>&1
tail -3 /tmp/pumaterm.out
