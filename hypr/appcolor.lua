-- App-coloured borders and title bars for floating windows.
--
--   SUPER + ALT + B, or the bar button, turns it on and off (`appcolor toggle`).
--
-- The plugin's service loads this file into Hyprland's Lua with
-- `hyprctl eval`, after setting AppColorDir to the plugin's folder, and loads
-- it again after every config reload, which starts Lua afresh.
--
-- Each window gets an `appcolor-<app>` tag. One rule per app gives focused
-- floating windows with that tag a colour taken from the app's icon.
-- Their title bars get a dark tint of the app's main colour.
-- Unfocused floating windows get a darker version of it as a window property:
-- Hyprland 0.56 does not draw an unfocused colour set by a rule (the border
-- vanishes), so that half is set per window. Tiled windows keep the theme
-- border. Colours come from bin/appcolor, which writes
-- ~/.local/state/appcolor/palette.lua and calls AppColor.reload() here.

-- Loaded again into the same Lua (the shell restarted, say): its event
-- handlers are already registered, so only refresh.
if AppColor and AppColor.loaded then
  AppColor.active = true
  AppColor.resync()
  return AppColor
end

local M = { loaded = true, active = true }
AppColor = M

local HOME = os.getenv("HOME")
local STATE = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/appcolor"
local DIR = AppColorDir or (HOME .. "/.config/omarchy/plugins/io.github.tuladhar.appcolor")
-- Quoted for the shell; the service refuses a folder with a quote in it.
local BIN = "'" .. DIR .. "/bin/appcolor'"
local PREFIX = "appcolor-"

local TERMINALS = {
  ["foot"] = true,
  ["footclient"] = true,
  ["alacritty"] = true,
  ["kitty"] = true,
  ["com.mitchellh.ghostty"] = true,
  ["org.omarchy.agent"] = true,
  ["org.omarchy.terminal"] = true,
}

-- Claude Code titles its terminal "✳ <task>" when idle and spins a glyph in
-- front of the task while working.
local CLAUDE_PREFIXES = { "✳", "✢", "✶", "✻", "✽", "◐", "◓", "◑", "◒", "·" }

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local enabled = file_exists(STATE .. "/enabled")
local palette = {}
local rules = {} -- tag -> { rule, border }
local requested = {} -- key -> true, so each app is resolved once per session

local function load_palette()
  local ok, t = pcall(dofile, STATE .. "/palette.lua")
  palette = (ok and type(t) == "table") and t or {}
end

local function is_claude(title)
  title = title or ""
  if title:find("Claude Code", 1, true) then return true end
  for _, p in ipairs(CLAUDE_PREFIXES) do
    if title:sub(1, #p + 1) == p .. " " then return true end
  end
  -- Braille spinner, U+2800..U+28FF (UTF-8 lead bytes E2 A0..A3).
  local b1, b2 = title:byte(1, 2)
  return b1 == 0xE2 and b2 and b2 >= 0xA0 and b2 <= 0xA3 or false
end

local function key_for(window)
  local class = string.lower(window.class or "")
  if class == "" then return nil end
  if TERMINALS[class] and is_claude(window.title) then return "claude" end
  local stem = class:match("^chrome%-(.+)%-default$") or class:match("^chrome%-(.+)%-profile_%d+$")
  if stem then return "web:" .. stem end
  return class
end

local function tag_for(key)
  return PREFIX .. (key:gsub("[^a-z0-9]", "-"))
end

local function ensure_rule(key)
  local border = palette[key]
  if not enabled or type(border) ~= "table" then return end
  local tag = tag_for(key)
  local existing = rules[tag]
  if existing and existing.border == border then
    existing.rule:set_enabled(true)
    if existing.bar then existing.bar:set_enabled(true) end
    return
  end
  local rule = hl.window_rule({
    name = tag,
    match = { tag = tag, float = true },
    border_color = border.active,
  })
  rule:set_enabled(true)
  -- Title bar tinted with the app's main colour (Omarchy's titlebar plugin).
  local bar
  if type(border.bar) == "string" then
    bar = hl.window_rule({
      name = tag .. "-bar",
      match = { tag = tag, float = true },
      ["hyprbars:bar_color"] = border.bar,
    })
    bar:set_enabled(true)
  end
  rules[tag] = { rule = rule, bar = bar, border = border }
end

-- Unfocused colour, set on the window itself. Hyprland's property parser drops
-- the first colour it is given, so the first colour is repeated: should that
-- ever be fixed, the doubled stop draws exactly the same gradient.
local applied = {} -- address -> value set

local function gradient_string(colors, angle)
  local parts = { colors[1] }
  for _, c in ipairs(colors) do parts[#parts + 1] = c end
  return table.concat(parts, " ") .. " " .. math.floor(angle or 0) .. "deg"
end

local function default_inactive()
  local v = hl.get_config("general.col.inactive_border")
  local colors = {}
  for _, n in ipairs(type(v) == "table" and v.colors or {}) do
    local hex = string.format("%08x", math.floor(n) & 0xffffffff)
    colors[#colors + 1] = "rgba(" .. hex:sub(3) .. hex:sub(1, 2) .. ")"
  end
  if #colors == 0 then colors = { "rgba(595959aa)" } end
  local angle = type(v) == "table" and tonumber(v.angle) or 0
  return gradient_string(colors, math.deg(angle))
end

local function set_inactive(window, value)
  if applied[window.address] == value then return end
  hl.dispatch(hl.dsp.window.set_prop({
    window = "address:" .. window.address,
    prop = "inactive_border_color",
    value = value,
  }))
  applied[window.address] = value
end

local function restore_inactive(window)
  if applied[window.address] then
    set_inactive(window, default_inactive())
    applied[window.address] = nil
  end
end

local function sync_inactive(window, key)
  local border = key and palette[key]
  if enabled and window.floating and type(border) == "table" then
    set_inactive(window, gradient_string(border.inactive.colors, border.inactive.angle))
  else
    restore_inactive(window)
  end
end

local pending = {}

local function flush_pending()
  local keys = {}
  for key in pairs(pending) do
    keys[#keys + 1] = "'" .. key .. "'"
  end
  pending = {}
  if #keys > 0 then
    hl.exec_cmd(BIN .. " resolve " .. table.concat(keys, " "))
  end
end

local function update_window(window, batch)
  if not M.active or not enabled or not window or not window.address then return end
  window = hl.get_window("address:" .. window.address) or window
  local key = key_for(window)
  if not key or #key > 128 or not key:match("^[a-z0-9:._+-]+$") then
    restore_inactive(window)
    return
  end

  local want = tag_for(key)
  local has = false
  for _, tag in ipairs(window.tags or {}) do
    local base = tag:gsub("%*$", "")
    if base == want then
      has = true
    elseif base:sub(1, #PREFIX) == PREFIX then
      hl.dispatch(hl.dsp.window.tag({ tag = "-" .. base, window = "address:" .. window.address }))
    end
  end
  if not has then
    hl.dispatch(hl.dsp.window.tag({ tag = "+" .. want, window = "address:" .. window.address }))
  end

  if palette[key] == nil and not requested[key] then
    requested[key] = true
    pending[key] = true
  end
  ensure_rule(key)
  sync_inactive(window, key)
  if not batch then flush_pending() end
end

-- Called by `appcolor` after it writes new colours.
function M.reload()
  if not M.active then return end
  load_palette()
  local live = {}
  for _, window in ipairs(hl.get_windows()) do
    if window.address then live[window.address] = true end
  end
  for address in pairs(applied) do
    if not live[address] then applied[address] = nil end
  end
  if not enabled then return end
  for _, window in ipairs(hl.get_windows()) do
    update_window(window, true)
  end
  flush_pending()
end

-- Called by `appcolor on|off|toggle`.
function M.set_enabled(on)
  enabled = on and true or false
  if enabled then
    M.reload()
  else
    for _, entry in pairs(rules) do
      entry.rule:set_enabled(false)
      if entry.bar then entry.bar:set_enabled(false) end
    end
    for _, window in ipairs(hl.get_windows()) do
      restore_inactive(window)
    end
  end
end

-- Picks the on/off state up from disk again, as at load.
function M.resync()
  M.set_enabled(file_exists(STATE .. "/enabled"))
end

-- Called by the plugin's service when the plugin is disabled or unloaded:
-- borders go back to the theme's, and the handlers below stop acting.
function M.shutdown()
  M.set_enabled(false)
  M.active = false
end

hl.on("window.open", function(window) update_window(window) end)
hl.on("window.title", function(window) update_window(window) end)
hl.on("window.class", function(window) update_window(window) end)
-- Floating or tiling a window re-runs its rules; follow it for the unfocused colour.
hl.on("window.update_rules", function(window) update_window(window) end)
-- A closing window can arrive without its address; M.reload() then prunes
-- the entry along with any other window that is gone.
hl.on("window.destroy", function(window)
  if M.active and window and window.address then applied[window.address] = nil end
end)

o.bind("SUPER + ALT + B", "Toggle app-coloured floating borders", BIN .. " toggle")

M.reload()

return M
