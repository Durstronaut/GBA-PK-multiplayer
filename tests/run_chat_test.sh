#!/bin/sh
# Map-local visibility suite: server runs with so three same-room
# clients trip local mode.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/gbapk-chattest"
rm -rf "$WORK"; mkdir -p "$WORK"
SRV=""
cleanup() { [ -n "$SRV" ] && kill -9 "$SRV" 2>/dev/null; }
trap cleanup EXIT INT TERM
cd "$WORK"
lua5.4 "$ROOT/server/GBA-PK-Server.lua" 4096 16 > server.log 2>&1 &
SRV=$!
sleep 1.2
grep -q "listening" server.log || { echo "ERROR: server failed to start"; cat server.log; exit 1; }
( cd "$ROOT" && lua5.4 tests/chat_companion_test.lua )
RC=$?
echo "chat companion test complete (rc=$RC)"
exit $RC
