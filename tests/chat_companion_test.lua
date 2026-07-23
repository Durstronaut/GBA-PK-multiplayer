-- Chat-companion integration test: a fake in-game client (Kanto) must receive
-- what the keyboard companion types, server-wrapped with its room name, and
-- the companion must receive in-game chat. Run via tests/run_chat_test.sh.
local socket = require("socket")
local FRAME = 64
local function fid(x) return string.format("%04d", 1000 + x) end
local function padded(text) return text .. string.rep("~", 43 - #text) end
local function frame(gameid, pid, sendto, ptype, reqbytes, extraTail)
  local extra = fid(reqbytes) .. string.rep("\0", 33) .. "F" .. "FFFFF"
  if extraTail then extra = extraTail end
  local f = gameid .. "FFFF" .. fid(pid) .. fid(sendto) .. ptype .. extra .. "U"
  assert(#f == FRAME)
  return f
end
local function ftype(f) return f:sub(17,20) end
local function fpid(f) return (tonumber(f:sub(9,12)) or 1000) - 1000 end
local function freqbytes(f) return (tonumber(f:sub(21,24)) or 1000) - 1000 end
local function fpayload(f) return (f:sub(21,63):gsub("~*$","")) end

local function pump(c, seconds)
  local deadline = socket.gettime() + (seconds or 0.4)
  while socket.gettime() < deadline do
    local d, err, part = c.sock:receive(65536)
    local chunk = d or part
    if chunk and #chunk > 0 then
      c.buf = c.buf .. chunk
      while #c.buf >= FRAME do
        c.frames[#c.frames+1] = c.buf:sub(1, FRAME)
        c.buf = c.buf:sub(FRAME+1)
      end
    end
    socket.sleep(0.01)
  end
end
local function findType(c, ty, pred)
  for _, f in ipairs(c.frames) do
    if ftype(f) == ty and (not pred or pred(f)) then return f end
  end
end

local pass, fail = 0, 0
local function check(cond, msg)
  if cond then pass = pass + 1; print("  PASS " .. msg)
  else fail = fail + 1; print("  FAIL " .. msg) end
end

-- fake in-game player joins Kanto
local G = { sock = assert(socket.connect("127.0.0.1", 4096)), buf = "", frames = {} }
G.sock:settimeout(0); G.sock:setoption("tcp-nodelay", true)
G.sock:send(frame("BPR1", 0, 0, "JOIN", 0))
pump(G, 0.5)
local gid = freqbytes(findType(G, "STRT") or frame("BPR1",0,0,"STRT",0))
check(gid and gid >= 2, "in-game client joined Kanto")

-- launch the keyboard companion with one line of piped input
local companion = assert(io.popen(
  "printf 'hello from keyboard\\n' | python3 chat/gba-pk-chat.py 127.0.0.1:4096 KEYB 2>&1", "r"))

G.frames = {}
pump(G, 3.0)
local kb = findType(G, "CHAT", function(f) return fpid(f) == 0 and fpayload(f):find("hello from keyboard") end)
check(kb ~= nil, "in-game client receives the companion's keyboard message")
check(kb and fpayload(kb):find("KEYB") ~= nil and fpayload(kb):find("CHAT") ~= nil,
      "message is attributed with name and room: " .. tostring(kb and fpayload(kb)))

-- in-game player replies; companion should print it (check its output)
G.sock:send(frame("BPR1", gid, 0, "CHAT", 0, padded("hi keyboard")))
socket.sleep(1.2)
G.sock:close()
local out = companion:read("*a") or ""
companion:close()
check(out:find("connected as player") ~= nil, "companion connected and announced itself")
check(out:find("hi keyboard") ~= nil, "companion received the in-game reply")

print(string.format("\n== RESULT: %d passed, %d failed ==", pass, fail))
os.exit(fail == 0 and 0 or 1)
