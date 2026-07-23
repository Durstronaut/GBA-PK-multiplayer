-- Map-local visibility test. Run against a server started with --local=2 so
-- three same-room clients are enough to trip local mode (see
-- tests/run_visibility_test.sh).
local socket = require("socket")
local FRAME = 64
local function fid(x) return string.format("%04d", 1000 + x) end

-- position-format frame with real map bytes (ExtraData 10-11 map, 12-13 prev)
local function posFrame(gameid, pid, sendto, ptype, reqbytes, map, prevmap)
  local extra = fid(reqbytes)
    .. string.rep("\0", 5)                                -- battle(4) + direction(1)
    .. string.char(map % 256, math.floor(map / 256) % 256)
    .. string.char((prevmap or map) % 256, math.floor((prevmap or map) / 256) % 256)
    .. string.rep("\0", 24)                               -- rest of the binary fields
    .. "F" .. "FFFFF"
  local f = gameid .. "FFFF" .. fid(pid) .. fid(sendto) .. ptype .. extra .. "U"
  assert(#f == FRAME, "len " .. #f)
  return f
end
local function ftype(f) return f:sub(17,20) end
local function freqbytes(f) return (tonumber(f:sub(21,24)) or 1000) - 1000 end
local function fpid(f) return (tonumber(f:sub(9,12)) or 1000) - 1000 end

local function newClient()
  local c = assert(socket.connect("127.0.0.1", 4096))
  c:settimeout(0); c:setoption("tcp-nodelay", true)
  return { sock = c, buf = "", frames = {} }
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

-- Maps: A and B start on map 100; C starts on map 200. Threshold is 2, so the
-- third join tips the Kanto room into local mode.
print("== Setup: A and B on map 100 (full visibility while small) ==")
local A = newClient()
A.sock:send(posFrame("BPR1", 0, 0, "JOIN", 0, 100))
pump(A, 0.5)
local aid = freqbytes(findType(A, "STRT"))
local B = newClient()
B.sock:send(posFrame("BPR1", 0, 0, "JOIN", 0, 100))
pump(B, 0.5); pump(A, 0.3)
local bid = freqbytes(findType(B, "STRT"))
check(findType(B, "APLA", function(f) return freqbytes(f) == aid end) ~= nil, "B sees A (small room = full visibility)")
check(findType(A, "APLA", function(f) return freqbytes(f) == bid end) ~= nil, "A sees B")

print("== C joins on map 200: local mode kicks in, C sees nobody ==")
A.frames = {}; B.frames = {}
local C = newClient()
C.sock:send(posFrame("BPR1", 0, 0, "JOIN", 0, 200))
pump(C, 0.5); pump(A, 0.3)
local cid = freqbytes(findType(C, "STRT"))
check(cid ~= nil and cid > 0, "C joins (map 200)")
check(findType(C, "APLA") == nil, "C is not introduced to anyone (different map)")
check(findType(A, "APLA", function(f) return freqbytes(f) == cid end) == nil, "A is not introduced to C")

print("== C's SPOS does not reach A; A and B still sync ==")
A.frames = {}; B.frames = {}
C.sock:send(posFrame("BPR1", cid, cid, "SPOS", cid, 200))
A.sock:send(posFrame("BPR1", aid, aid, "SPOS", aid, 100))
pump(B, 0.4); pump(A, 0.3)
check(findType(A, "SPOS", function(f) return fpid(f) == cid end) == nil, "C's movement is not relayed to A")
check(findType(B, "SPOS", function(f) return fpid(f) == aid end) ~= nil, "A's movement still reaches B (same map)")

print("== C walks onto map 100: introduced to A and B ==")
A.frames = {}; C.frames = {}
C.sock:send(posFrame("BPR1", cid, cid, "SPOS", cid, 100, 200))
pump(A, 0.5); pump(C, 0.3)
check(findType(A, "APLA", function(f) return freqbytes(f) == cid end) ~= nil, "A is introduced to C on arrival")
check(findType(C, "APLA", function(f) return freqbytes(f) == aid end) ~= nil, "C is introduced to A on arrival")

print("== A leaves for map 300: removed from B and C via RPLA ==")
B.frames = {}; C.frames = {}
A.sock:send(posFrame("BPR1", aid, aid, "SPOS", aid, 300, 100))
socket.sleep(0.2)
-- prevmap linkage keeps the pair visible during the transition; a second SPOS
-- fully on map 300 severs it
A.sock:send(posFrame("BPR1", aid, aid, "SPOS", aid, 300, 300))
pump(B, 0.5); pump(C, 0.3)
check(findType(B, "RPLA", function(f) return freqbytes(f) == aid end) ~= nil, "B removes A after A leaves the map")
check(findType(C, "RPLA", function(f) return freqbytes(f) == aid end) ~= nil, "C removes A too")

A.sock:close(); B.sock:close(); C.sock:close()
print(string.format("\n== RESULT: %d passed, %d failed ==", pass, fail))
os.exit(fail == 0 and 0 or 1)
