-- oracle.lua — Hammerspoon-side ground-truth helpers for qa-windowscape.sh.
--
-- Loaded fresh on every `hs -c` call via dofile; all functions are stateless
-- and return plain strings (the bash orchestrator does the sequencing).
--
-- Eligibility mirror: windowscape tiles standard, visible, non-minimized,
-- non-collapsed (h > 12px) windows of apps NOT in its exclusion list
-- (cfg.exclusionMode = true, listedApps persisted in the UserDefaults suite
-- com.stackd.stack.windowscape). The bash side reads that list with
-- `defaults read` and passes it in as a CSV so this file stays settings-free.
--
-- Empirical note on the stackd overlay panel: hs.window.allWindows() does
-- NOT reveal it (borderless non-activating NSPanel from an .accessory app —
-- no AXStandardWindow subrole, and hs's app-window walk skips it). The
-- overlay check therefore lives in cgwindows.js (CGWindowListCopyWindowInfo
-- via JXA); qa.stackdPanelsViaHs() below exists only to document/verify that
-- negative result at preflight time.

local qa = {}

local COLLAPSED_MAX_H = 14 -- windowscape cfg.collapsedWindowHeight (12) + slack

local function splitCsv(s)
  local t = {}
  if s and s ~= "" then
    for item in string.gmatch(s, "([^,]+)") do t[item] = true end
  end
  return t
end

local function byId(id)
  id = tonumber(id)
  if not id then return nil end
  for _, w in ipairs(hs.window.allWindows()) do
    if w:id() == id then return w end
  end
  return nil
end

-- Oracle mirror of windowscape's tiled set on the primary display,
-- sorted left-to-right.
local function eligibleWindows(excludedCsv)
  local excluded = splitCsv(excludedCsv)
  local scr = hs.screen.primaryScreen()
  local out = {}
  for _, w in ipairs(hs.window.allWindows()) do
    if w:isStandard() and w:isVisible() and not w:isMinimized() then
      local app = w:application()
      local name = app and app:name() or ""
      local bid = (app and app:bundleID()) or ""
      if not excluded[name] and not excluded[bid] then
        local f = w:frame()
        local ws = w:screen()
        if f.h > COLLAPSED_MAX_H and ws and scr and ws:id() == scr:id() then
          out[#out + 1] = w
        end
      end
    end
  end
  table.sort(out, function(a, b) return a:frame().x < b:frame().x end)
  return out
end

local function round2(v) return math.floor(v / 2 + 0.5) * 2 end

-- Stability signature: "id:x,y,w,h|id:x,y,w,h" sorted by id, coords rounded
-- to 2px so AX jitter doesn't flap consecutive samples.
function qa.sig(excludedCsv)
  local wins = eligibleWindows(excludedCsv)
  local parts = {}
  for _, w in ipairs(wins) do
    local f = w:frame()
    parts[#parts + 1] = string.format("%d:%d,%d,%d,%d",
      w:id(), round2(f.x), round2(f.y), round2(f.w), round2(f.h))
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

-- Human-readable dump for failure details.
function qa.eligible(excludedCsv)
  local wins = eligibleWindows(excludedCsv)
  local parts = {}
  for _, w in ipairs(wins) do
    local f = w:frame()
    local app = w:application()
    parts[#parts + 1] = string.format("%d=%s[%d,%d,%dx%d]",
      w:id(), app and app:name() or "?", f.x, f.y, f.w, f.h)
  end
  return table.concat(parts, " ")
end

-- JSON dump of eligible windows — consumed by cgwindows.js as the candidate
-- list when reporting which window the overlay actually frames.
function qa.framesJson(excludedCsv)
  local wins = eligibleWindows(excludedCsv)
  local arr = {}
  for _, w in ipairs(wins) do
    local f = w:frame()
    local app = w:application()
    arr[#arr + 1] = { id = w:id(), app = app and app:name() or "?",
                      x = f.x, y = f.y, w = f.w, h = f.h }
  end
  return hs.json.encode(arr)
end

local function overlapArea(f1, f2)
  local ix = math.min(f1.x + f1.w, f2.x + f2.w) - math.max(f1.x, f2.x)
  local iy = math.min(f1.y + f1.h, f2.y + f2.h) - math.max(f1.y, f2.y)
  if ix <= 0 or iy <= 0 then return 0 end
  return ix * iy
end

-- I1: pairwise intersection area <= 25 px^2 (1-2px AX rounding allowance).
function qa.checkI1(excludedCsv)
  local wins = eligibleWindows(excludedCsv)
  for i = 1, #wins do
    for j = i + 1, #wins do
      local a = overlapArea(wins[i]:frame(), wins[j]:frame())
      if a > 25 then
        local ai = wins[i]:application(); local aj = wins[j]:application()
        return string.format("FAIL overlap %d(%s) x %d(%s) area=%dpx2",
          wins[i]:id(), ai and ai:name() or "?",
          wins[j]:id(), aj and aj:name() or "?", a)
      end
    end
  end
  return "OK"
end

-- I2 layout shape (lenient, per harness spec): I1 + same-row (y within 5px;
-- height deliberately NOT asserted — height refusals are app-specific noise)
-- + combined width within 15% of the primary work-area width (absorbs the
-- snapshots-strip reservation, 140px right column on landscape, without the
-- oracle needing windowscape-internal snapshot state).
function qa.checkI2(excludedCsv)
  local wins = eligibleWindows(excludedCsv)
  if #wins == 0 then return "FAIL no-eligible-windows" end
  local i1 = qa.checkI1(excludedCsv)
  if i1 ~= "OK" then return i1 end

  local minY, maxY = math.huge, -math.huge
  local sumW = 0
  for _, w in ipairs(wins) do
    local f = w:frame()
    if f.y < minY then minY = f.y end
    if f.y > maxY then maxY = f.y end
    sumW = sumW + f.w
  end
  if maxY - minY > 5 then
    return string.format("FAIL not-same-row ymin=%d ymax=%d wins=%s",
      minY, maxY, qa.eligible(excludedCsv))
  end
  local scrW = hs.screen.primaryScreen():frame().w
  if math.abs(sumW - scrW) > 0.15 * scrW then
    return string.format("FAIL width-partition sumW=%d workareaW=%d wins=%s",
      sumW, scrW, qa.eligible(excludedCsv))
  end
  return "OK n=" .. #wins
end

-- I3 pair-locality. preSig is qa.sig() output captured BEFORE the resize.
-- After growing A's right edge by +150: A.w grew ~150 (±25), B changed
-- (>5px on x or w), every OTHER window in preSig unchanged (≤5px each of
-- x/y/w/h). Plus I1.
function qa.checkI3(excludedCsv, aId, bId, preSig)
  aId, bId = tonumber(aId), tonumber(bId)
  local pre = {}
  for id, x, y, w, h in string.gmatch(preSig, "(%d+):(%-?%d+),(%-?%d+),(%d+),(%d+)") do
    pre[tonumber(id)] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
  end
  if not pre[aId] or not pre[bId] then return "FAIL bad-pre-sig (A/B missing)" end

  local offenders = {}
  local aVerdict, bVerdict = nil, nil
  for id, p in pairs(pre) do
    local w = byId(id)
    if not w then
      if id ~= aId and id ~= bId then
        offenders[#offenders + 1] = string.format("%d(gone)", id)
      end
    else
      local f = w:frame()
      local dx, dy = f.x - p.x, f.y - p.y
      local dw, dh = f.w - p.w, f.h - p.h
      local app = w:application() and w:application():name() or "?"
      if id == aId then
        if math.abs(dw - 150) > 25 then
          aVerdict = string.format("A-width dW=%d (wanted ~150)", dw)
        end
      elseif id == bId then
        if math.abs(dw) <= 5 and math.abs(dx) <= 5 then
          bVerdict = string.format("B-unchanged dx=%d dW=%d (expected to absorb)", dx, dw)
        end
      else
        if math.abs(dx) > 5 or math.abs(dy) > 5 or math.abs(dw) > 5 or math.abs(dh) > 5 then
          offenders[#offenders + 1] = string.format("%d(%s dx=%d dy=%d dW=%d dH=%d)",
            id, app, dx, dy, dw, dh)
        end
      end
    end
  end
  local i1 = qa.checkI1(excludedCsv)
  local probs = {}
  if aVerdict then probs[#probs + 1] = aVerdict end
  if bVerdict then probs[#probs + 1] = bVerdict end
  if #offenders > 0 then
    probs[#probs + 1] = "non-adjacent-changed: " .. table.concat(offenders, " ")
  end
  if i1 ~= "OK" then probs[#probs + 1] = i1 end
  if #probs == 0 then return "OK" end
  return "FAIL " .. table.concat(probs, "; ")
end

-- ---- window driver --------------------------------------------------------

function qa.findByTitle(substr)
  for _, w in ipairs(hs.window.allWindows()) do
    local t = w:title() or ""
    if t:find(substr, 1, true) then return tostring(w:id()) end
  end
  return ""
end

function qa.frame(id)
  local w = byId(id)
  if not w then return "ERR no-window " .. tostring(id) end
  local f = w:frame()
  return string.format("%d %d %d %d", f.x, f.y, f.w, f.h)
end

function qa.moveToPrimary(id)
  local w = byId(id)
  if not w then return "ERR no-window " .. tostring(id) end
  local scr = hs.screen.primaryScreen()
  if w:screen() and w:screen():id() ~= scr:id() then
    w:moveToScreen(scr, false, true, 0)
    return "moved"
  end
  return "already-primary"
end

-- Grow the window's right edge by dw px (x/y/h unchanged, duration 0 —
-- a pure AX resize, which windowscape routes to its drift watcher).
function qa.growRight(id, dw)
  local w = byId(id)
  if not w then return "ERR no-window " .. tostring(id) end
  local f = w:frame()
  f.w = f.w + tonumber(dw)
  w:setFrame(f, 0)
  return "ok"
end

function qa.closeWin(id)
  local w = byId(id)
  if not w then return "already-gone" end
  w:close()
  return "closed"
end

function qa.minimize(id)
  local w = byId(id)
  if not w then return "ERR no-window " .. tostring(id) end
  w:minimize()
  return "ok"
end

function qa.unminimize(id)
  local w = byId(id)
  if not w then return "ERR no-window " .. tostring(id) end
  w:unminimize()
  return "ok"
end

function qa.isMin(id)
  local w = byId(id)
  if not w then return "ERR no-window " .. tostring(id) end
  return tostring(w:isMinimized())
end

function qa.focusWin(id)
  local w = byId(id)
  if not w then return "ERR no-window " .. tostring(id) end
  w:focus()
  return "ok"
end

function qa.focusedId()
  local w = hs.window.focusedWindow()
  return w and tostring(w:id()) or ""
end

-- ---- different-app window for S5 (Hammerspoon console: zero cleanup risk) --

function qa.openConsole()
  hs.openConsole(true)
  for _, w in ipairs(hs.window.allWindows()) do
    local app = w:application()
    if app and app:name() == "Hammerspoon" and (w:title() or ""):find("Console", 1, true) then
      return tostring(w:id())
    end
  end
  return ""
end

function qa.closeConsole()
  hs.closeConsole()
  return "ok"
end

-- ---- preflight helpers ------------------------------------------------------

function qa.isLandscape()
  local f = hs.screen.primaryScreen():frame()
  return tostring(f.w > f.h)
end

-- Documents the hs-side overlay-panel detection attempt: expected to return
-- "NONE" (see header comment); the harness records the result and uses
-- cgwindows.js as the actual oracle.
function qa.stackdPanelsViaHs()
  local found = {}
  for _, w in ipairs(hs.window.allWindows()) do
    local app = w:application()
    if app and app:name() == "stackd" then
      local f = w:frame()
      found[#found + 1] = string.format("%d[%d,%d,%dx%d]", w:id(), f.x, f.y, f.w, f.h)
    end
  end
  if #found == 0 then return "NONE" end
  return table.concat(found, " ")
end

-- Cleanup failsafe: close every window whose title contains the qa marker.
function qa.closeAllQa(marker)
  local n = 0
  for _, w in ipairs(hs.window.allWindows()) do
    local t = w:title() or ""
    if t:find(marker, 1, true) then
      w:close()
      n = n + 1
    end
  end
  return tostring(n)
end

return qa
