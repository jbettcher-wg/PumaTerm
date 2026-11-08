#!/bin/sh
# Run Term in the console user's session behind other windows, type a test
# line into it, and dump its own frame to /tmp/term-frame.png.
# Processes are matched by executable name (ps comm), never by command line,
# so this script cannot match itself.
termpids() { ps -axo pid=,comm= | awk '$2 ~ /MacOS\/term$/ {print $1}'; }
for p in $(termpids); do kill $p; done
sleep 1
cd /Applications && rm -rf Term.app && tar xzf /tmp/Term.app.tgz 2>/dev/null && chown -R jbettcher:admin Term.app
rm -f /tmp/term-frame.png
FINDER=$(ps -axo pid=,user=,comm= | awk '$2=="jbettcher" && $3 ~ /Finder$/ {print $1}' | head -1)
INPUT=$(cat /tmp/termtest.input)
launchctl bsexec "$FINDER" sudo -u jbettcher -H env TERM_STARTUP_INPUT="$INPUT" \
	/Applications/Term.app/Contents/MacOS/term $TERM_ARGS > /tmp/term.out 2>&1 &
sleep ${WAIT:-6}
P=$(termpids)
echo "term pid: ${P:-none}"
[ -n "$P" ] && kill -USR1 $P
sleep 2
ls -la /tmp/term-frame.png 2>&1
tail -3 /tmp/term.out
