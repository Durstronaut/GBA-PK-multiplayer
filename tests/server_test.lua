-- Integration test for GBA-PK-Server.lua using two fake luasocket clients.
local socket = require("socket")
local FRAME = 64
local function fid(x) return string.format("%04d", 1000 + x) end
local function frame(gameid, pid, sendto, ptype, reqbytes, extraTail)
  local extra = fid(reqbytes) .. string.rep("\0", 33) .. "F" .. "FFFFF"
  if extraTail then extra = extraTail end
  local f = gameid .. "FFFF" .. fid(pid) .. fid(sendto) .. ptype .. extra .. "U"
  assert(#f == FRAME, "built frame len " .. #f)
  return f
end
local function ftype(f) return f:sub(17,20) end
local function freqbytes(f) return (tonumber(f:sub(21,24)) or 1000) - 1000 end
local function fpid(f) return (tonumber(f:sub(9,12)) or 1000) - 1000 end
local function fdedicated(f) return f:sub(21+37, 21+37) == "D" end

local function newClient(gameid)
  local c = assert(socket.connect("127.0.0.1", 4096))
  c:settimeout(0); c:setoption("tcp-nodelay", true)
  return { sock = c, buf = "", frames = {}, gameid = gameid }
end
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
local function typesOf(c)
  local t = {}
  for _, f in ipairs(c.frames) do t[#t+1] = ftype(f) end
  return table.concat(t, ",")
end
local function findType(c, ty)
  for _, f in ipairs(c.frames) do if ftype(f) == ty then return f end end
end

local pass, fail = 0, 0
local function check(cond, msg)
  if cond then pass = pass + 1; print("  PASS " .. msg)
  else fail = fail + 1; print("  FAIL " .. msg) end
end

print("== Client A joins ==")
local A = newClient("BPR1")
A.sock:send(frame("BPR1", 0, 0, "JOIN", 0))
pump(A, 0.5)
print("  A got: " .. typesOf(A))
local strt = findType(A, "STRT")
check(strt ~= nil, "A receives STRT")
check(strt and fdedicated(strt), "STRT carries the dedicated-server flag (D)")
local myId = strt and freqbytes(strt)
check(myId == 2, "A is assigned player id 2 (ids start at 2, not 1) [got " .. tostring(myId) .. "]")
check(findType(A, "GNIC") ~= nil, "A receives GNIC (server asks for nickname)")

print("== Client B joins ==")
local B = newClient("BPR1")
B.sock:send(frame("BPR1", 0, 0, "JOIN", 0))
pump(B, 0.5)
local strtB = findType(B, "STRT")
check(strtB and freqbytes(strtB) == 3, "B is assigned player id 3 [got " .. tostring(strtB and freqbytes(strtB)) .. "]")
check(findType(B, "APLA") ~= nil, "B is introduced to A via APLA")
-- A should now be told about B
A.frames = {}; pump(A, 0.4)
local aplaOnA = findType(A, "APLA")
check(aplaOnA ~= nil, "A is introduced to B via APLA")
check(aplaOnA and freqbytes(aplaOnA) == 3, "the APLA A got is for player 3 (B)")

print("== SPOS relay ==")
A.frames = {}; B.frames = {}
-- B sends a position update; A should receive it, B should not echo
B.sock:send(frame("BPR1", 3, 3, "SPOS", 3))
pump(A, 0.4); pump(B, 0.2)
local sposOnA = findType(A, "SPOS")
check(sposOnA ~= nil, "A receives B's SPOS (relayed)")
check(sposOnA and fpid(sposOnA) == 3, "relayed SPOS is from player 3")
check(findType(B, "SPOS") == nil, "B does not receive its own SPOS back")

print("== Targeted relay (trade-style) to a peer ==")
A.frames = {}
-- B sends a targeted packet to A (id 2)
B.sock:send(frame("BPR1", 3, 2, "TRAD", 3))
pump(A, 0.4)
check(findType(A, "TRAD") ~= nil, "targeted TRAD from B reaches A (its SendToID)")

print("== Targeted relay to a missing player -> TBUS ==")
B.frames = {}
B.sock:send(frame("BPR1", 3, 99, "TRAD", 3))   -- 99 doesn't exist
pump(B, 0.4)
check(findType(B, "TBUS") ~= nil, "targeting a missing player returns TBUS to sender")

print("== Disconnect announce (DISC) ==")
A.frames = {}
B.sock:close()   -- B leaves
pump(A, 1.2)     -- server detects close, tells A
local disc = findType(A, "DISC")
check(disc ~= nil, "A is told B left via DISC")
check(disc and freqbytes(disc) == 3, "DISC names player 3 (B) [got " .. tostring(disc and freqbytes(disc)) .. "]")

A.sock:close()
print(string.format("\n== RESULT: %d passed, %d failed ==", pass, fail))
os.exit(fail == 0 and 0 or 1)
