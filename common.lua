-- common.lua
-- Shared utilities for all WiresharkPlugin scripts.
--
-- HOW TO USE IN A PLUGIN:
--   local COMMON_PATH = debug.getinfo(1,"S").source:match("@(.*[/\\])") or ""
--   local M = dofile(COMMON_PATH .. "common.lua")
--
-- NOTE: dofile is used (not require) because Wireshark shares one Lua state
-- across plugins but resets package.loaded on reload. dofile is always safe.
--
-- Author: Yang Xing (hongch_911@126.com)  /  refactored 2025
--------------------------------------------------------------------------------

-- Singleton guard: all plugins dofile() this module; return cached copy after
-- the first load to avoid redundant work in the shared Lua state.
if _G.__ws_common then return _G.__ws_common end

local M = {}

-- ---------------------------------------------------------------------------
-- Bit-operation compatibility  (Lua 5.1 / 5.2 / 5.3 / 5.4)
-- Returns a table: { band, bor, lshift, rshift }
-- ---------------------------------------------------------------------------
function M.make_bit()
    local ver = tonumber(string.match(_VERSION, "%d+%.%d*")) or 5.1
    if ver >= 5.3 then          -- 5.3 introduced integer arithmetic operators
        return {
            band   = function(a, b) return a & b  end,
            bor    = function(a, b) return a | b  end,
            lshift = function(a, b) return a << b end,
            rshift = function(a, b) return a >> b end,
        }
    elseif ver >= 5.2 then
        return require("bit32")
    else
        return require("bit")
    end
end

-- ---------------------------------------------------------------------------
-- Path helpers
-- ---------------------------------------------------------------------------

--- Returns a writable temp directory path (does NOT create it yet).
function M.get_temp_path()
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if home and home ~= "" then
        return home .. "/wireshark_temp"
    end
    return persconffile_path("temp")
end

--- Returns the ffmpeg bin/ prefix (with trailing slash), or "" if $FFMPEG unset.
function M.get_ffmpeg_path()
    local env = os.getenv("FFMPEG")
    if not env or env == "" then return "" end
    if env:sub(-5) ~= "/bin/" then env = env .. "/bin/" end
    return env
end

-- ---------------------------------------------------------------------------
-- String helpers  (pure functions – do NOT patch string metatable)
-- ---------------------------------------------------------------------------
function M.str_ends(s, suffix)
    return suffix == "" or s:sub(-#suffix) == suffix
end

function M.str_starts(s, prefix)
    return s:sub(1, #prefix) == prefix
end

-- ---------------------------------------------------------------------------
-- Pref range string -> array of integers
-- "96,98-100" -> {96, 98, 99, 100}
-- ---------------------------------------------------------------------------
function M.parse_pt_range(str)
    local list = {}
    str:gsub("[^,]+", function(w)
        local dash = w:find("-")
        if not dash then
            local n = tonumber(w)
            if n then table.insert(list, n) end
        else
            local lo = tonumber(w:sub(1, dash - 1))
            local hi = tonumber(w:sub(dash + 1))
            if lo and hi then
                for pt = lo, hi do table.insert(list, pt) end
            end
        end
    end)
    return list
end

-- ---------------------------------------------------------------------------
-- Dynamic payload-type registration / restoration
-- ---------------------------------------------------------------------------

--- Register proto for each pt in pt_numbers.  Returns old dissector table.
function M.register_dyn_pt(pt_table, pt_numbers, proto)
    local old = {}
    for i, pt in ipairs(pt_numbers) do
        old[i] = pt_table:get_dissector(pt)
        pt_table:add(pt, proto)
    end
    return old
end

--- Restore previously saved dissectors (or just remove proto if old[i] is nil).
function M.unregister_dyn_pt(pt_table, pt_numbers, proto, old)
    for i, pt in ipairs(pt_numbers) do
        if old and old[i] then
            pt_table:add(pt, old[i])
        else
            pt_table:remove(pt, proto)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Stream-info table helpers
-- ---------------------------------------------------------------------------

--- Returns a stable per-stream string key from pinfo.
function M.stream_key(pinfo)
    local k = string.format("from_%s_%s_to_%s_%s",
        tostring(pinfo.src), tostring(pinfo.src_port),
        tostring(pinfo.dst), tostring(pinfo.dst_port))
    return k:gsub(":", ".")
end

--- Get-or-create a stream_info record.
---   stream_infos  table   shared map {key -> info}
---   pinfo         Wireshark pinfo
---   temp_path     string  directory for output files
---   ext           string  file extension e.g. ".264"
---   twappend      function(string)  log callback
---   file_header   string|nil  bytes to write at file creation time
function M.get_or_create_stream(stream_infos, pinfo, temp_path, ext, twappend, file_header)
    local key  = M.stream_key(pinfo)
    local info = stream_infos[key]
    if info then return info end

    info          = {}
    info.filename = key .. ext
    info.filepath = temp_path .. "/" .. info.filename
    info.counter  = 0
    info.counter2 = 0

    if not Dir.exists(temp_path) then Dir.make(temp_path) end

    local f, err = io.open(info.filepath, "wb")
    if err then
        twappend("io.open error: " .. info.filepath .. " -> " .. err)
    else
        info.file = f
        if file_header then f:write(file_header) end
    end

    stream_infos[key] = info
    twappend(string.format(
        "Exporting RTP %s:%s -> %s:%s  =>  [%s]",
        tostring(pinfo.src), tostring(pinfo.src_port),
        tostring(pinfo.dst), tostring(pinfo.dst_port),
        info.filename))
    return info
end

--- Flush and close all open stream files.
--- Returns a list of completed stream_info records (for UI button creation).
function M.close_all_streams(stream_infos, twappend)
    local done = {}
    if not stream_infos then return done end
    for _, info in pairs(stream_infos) do
        if info and info.file then
            info.file:flush()
            info.file:close()
            info.file = nil
            twappend("[" .. info.filename .. "] generated OK!")
            table.insert(done, info)
        end
    end
    return done
end

-- ---------------------------------------------------------------------------
-- Generic export-window builder
--
-- Builds a TextWindow with Export All / Set Filter buttons and tap wiring.
--
-- Required opts fields:
--   title           string    TextWindow / ProgDlg title
--   tap_filter_base string    base Wireshark display filter, e.g. "h264"
--   filter_string   string    user-supplied extra filter (may be nil/"")
--   temp_path       string
--   ffmpeg_path     string
--   two_pass        bool      true -> retap twice (count pass + write pass)
--   dialog_reopen   function  called when user clicks "Set Filter"
--
--   on_packet(pinfo, tvb, stream_infos, first_run, pgtw, twappend)
--     called for every matching frame during retap
--
--   on_done(finished_streams, tw, twappend, ffmpeg_path, temp_path)
--     called after retap(s) complete; responsible for adding play buttons etc.
-- ---------------------------------------------------------------------------
function M.build_export_window(opts)
    local tw = TextWindow.new(opts.title)

    -- All TextWindow callbacks share this local; avoids global leakage.
    local function twappend(s)
        tw:append(s)
        tw:append("\n")
    end

    -- Build composite display filter
    local base  = opts.tap_filter_base
    local fstr  = opts.filter_string
    local tfilter
    if not fstr or fstr == "" then
        tfilter = base
    elseif fstr:find(base, 1, true) then
        tfilter = fstr
    else
        tfilter = base .. " && " .. fstr
    end
    twappend("Listener filter: " .. tfilter .. "\n")

    local stream_infos = nil
    local first_run    = true
    local pgtw         = nil

    local tap = Listener.new("frame", tfilter)

    function tap.packet(pinfo, tvb)
        if not stream_infos then return end
        opts.on_packet(pinfo, tvb, stream_infos, first_run, pgtw, twappend)
    end

    function tap.reset()
        -- intentionally empty; state is reset before each retap_packets() call
    end

    tw:set_atclose(function()
        tap:remove()
        if Dir.exists(opts.temp_path) then
            Dir.remove_all(opts.temp_path)
        end
    end)

    local function do_export()
        if opts.two_pass then
            pgtw       = ProgDlg.new(opts.title, "Exporting…")
            first_run  = true
            stream_infos = {}
            retap_packets()      -- pass 1: count packets / collect SPS/PPS
            first_run  = false
            retap_packets()      -- pass 2: write to files
        else
            stream_infos = {}
            retap_packets()
        end

        local done = M.close_all_streams(stream_infos, twappend)
        opts.on_done(done, tw, twappend, opts.ffmpeg_path, opts.temp_path)

        if pgtw then pgtw:close(); pgtw = nil end
        stream_infos = nil
    end

    tw:add_button("Export All",  do_export)
    tw:add_button("Set Filter",  function()
        tw:close()
        opts.dialog_reopen()
    end)
end

_G.__ws_common = M
return M
