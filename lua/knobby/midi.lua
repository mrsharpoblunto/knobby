local M = {}

local config_module = require("knobby.config")

local config
local controller
local handlers = {}
local process
local reconnect_timer
local generation = 0
local stdout_buffer = ""
local stderr_buffer = ""

local state = {
  desired = false,
  status = "stopped",
  backend = nil,
  port = nil,
  device = nil,
  error = nil,
}

local function notify(message, level)
  if config and config.ui and config.ui.notifications then
    vim.notify(message, level or vim.log.levels.INFO, { title = "Knobby" })
  end
end

local function set_status(status, details)
  state.status = status
  details = details or {}
  state.backend = config and config_module.effective_backend(config) or nil
  state.port = details.port
  state.device = details.device
  state.error = details.error
  if handlers.on_status then
    handlers.on_status(vim.deepcopy(state))
  end
end

local function effective_backend()
  return config_module.effective_backend(config)
end

local function backend_args(kind, port)
  local backend = effective_backend()
  if backend == "amidi" then
    if kind == "list" then
      return { "--list-devices" }
    end
    return { "--port", port, "--dump" }
  elseif backend == "receivemidi" then
    if kind == "list" then
      return { "list" }
    end
    return { "dev", port, "nn" }
  end
  error("knobby: unsupported MIDI backend: " .. tostring(backend))
end

local function failure_message()
  return effective_backend() .. " failed"
end

local function result_error(result)
  local message = vim.trim(result.stderr or "")
  return message ~= "" and message or failure_message()
end

local function command_with(...)
  local configured_command = config_module.effective_command(config)
  local command = type(configured_command) == "table"
      and vim.deepcopy(configured_command)
    or { configured_command }
  if effective_backend() == "amidi"
    and config.midi.line_buffered
    and vim.fn.executable("stdbuf") == 1
  then
    local line_buffered = { "stdbuf", "-oL", "-eL" }
    vim.list_extend(line_buffered, command)
    command = line_buffered
  end
  vim.list_extend(command, { ... })
  return command
end

local function read_first_line(path)
  local ok, lines = pcall(vim.fn.readfile, path, "", 1)
  if ok and lines[1] then
    return vim.trim(lines[1])
  end
end

local function sound_card_serial(card_index)
  local path = vim.uv.fs_realpath("/sys/class/sound/card" .. card_index .. "/device")
  while path and path ~= "/" do
    local serial = read_first_line(path .. "/serial")
    if serial then
      return serial
    end
    local parent = vim.fs.dirname(path)
    if parent == path then
      break
    end
    path = parent
  end
end

function M.parse_amidi_devices(output)
  local devices = {}
  for line in (output or ""):gmatch("[^\r\n]+") do
    local direction, raw_port, name = line:match("^%s*([IO]+)%s+(hw:[^%s]+)%s+(.+)%s*$")
    if direction and direction:find("I", 1, true) then
      local card_index, device_index, subdevice_index = raw_port:match("^hw:(%d+),(%d+),(%d+)$")
      if card_index then
        local card = read_first_line("/proc/asound/card" .. card_index .. "/id")
        devices[#devices + 1] = {
          direction = direction,
          raw_port = raw_port,
          port = card and string.format("hw:%s,%s,%s", card, device_index, subdevice_index) or raw_port,
          name = vim.trim(name),
          card = card,
          card_index = tonumber(card_index),
          device_index = tonumber(device_index),
          subdevice_index = tonumber(subdevice_index),
          usb_id = read_first_line("/proc/asound/card" .. card_index .. "/usbid"),
          serial = sound_card_serial(card_index),
        }
      end
    end
  end
  return devices
end

function M.parse_receivemidi_devices(output)
  local devices = {}
  for line in (output or ""):gmatch("[^\r\n]+") do
    local name = vim.trim(line)
    name = name:gsub("^%[%d+%]%s*", ""):gsub("^%d+:%s*", "")
    name = name:match('^"(.*)"$') or name
    local lower = name:lower()
    if name ~= ""
      and not lower:match("^midi input ports:?$")
      and not lower:match("^available midi input")
      and not lower:match("^no midi")
    then
      devices[#devices + 1] = {
        direction = "I",
        raw_port = name,
        port = name,
        name = name,
      }
    end
  end
  return devices
end

function M.parse_devices(output, backend)
  backend = backend or (config and effective_backend()) or "amidi"
  if backend == "receivemidi" then
    return M.parse_receivemidi_devices(output)
  end
  return M.parse_amidi_devices(output)
end

local function effective_match()
  local profile_match = vim.deepcopy(controller and controller.device_match or {})
  if effective_backend() == "receivemidi" then
    -- CoreMIDI port enumeration exposes names, not ALSA card/USB metadata.
    profile_match = {
      name = profile_match.name,
      port = profile_match.port,
    }
  end
  return vim.tbl_deep_extend("force", profile_match, config.midi.match or {})
end

local function field_matches(candidate, key, expected)
  if expected == nil or expected == false or expected == "" then
    return true
  end
  local actual = candidate[key]
  if not actual then
    return false
  end
  if key == "name" then
    local ok, matched = pcall(string.match, actual, expected)
    return ok and matched ~= nil
  end
  return tostring(actual):lower() == tostring(expected):lower()
end

local function matching_devices(devices)
  local match = effective_match()
  local has_matcher = next(match) ~= nil
  if not has_matcher then
    return devices
  end
  return vim.tbl_filter(function(candidate)
    return field_matches(candidate, "name", match.name)
      and field_matches(candidate, "card", match.card)
      and field_matches(candidate, "usb_id", match.usb_id)
      and field_matches(candidate, "serial", match.serial)
      and field_matches(candidate, "port", match.port)
  end, devices)
end

function M.list_devices_sync(timeout_ms)
  if not config then
    return nil, "Knobby is not configured"
  end
  local result = vim.system(command_with(unpack(backend_args("list"))), { text = true })
    :wait(timeout_ms or 2000)
  if result.code ~= 0 then
    return nil, result_error(result)
  end
  return M.parse_devices(result.stdout, effective_backend())
end

function M.list_devices(callback)
  vim.system(command_with(unpack(backend_args("list"))), { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, result_error(result))
      else
        callback(M.parse_devices(result.stdout, effective_backend()))
      end
    end)
  end)
end

function M.parse_amidi_line(line)
  local bytes = {}
  for byte in line:gmatch("%x%x") do
    bytes[#bytes + 1] = tonumber(byte, 16)
  end
  if #bytes < 3 or bytes[1] < 0x80 then
    return nil
  end

  local status = math.floor(bytes[1] / 16) * 16
  local channel = bytes[1] % 16 + 1
  if status == 0x90 then
    return { type = "note", channel = channel, number = bytes[2], value = bytes[3], raw = bytes }
  elseif status == 0x80 then
    return { type = "note", channel = channel, number = bytes[2], value = 0, raw = bytes }
  elseif status == 0xB0 then
    return { type = "cc", channel = channel, number = bytes[2], value = bytes[3], raw = bytes }
  end
end

function M.parse_receivemidi_line(line)
  line = vim.trim(line or "")
  local fields = "%s+(%d+)%s+([%a%-]+)%s+(%d+)%s+(%d+)"
  local channel, command, number, value = line:match("%f[%a]channel" .. fields)
  if not channel then
    channel, command, number, value = line:match("%f[%a]ch" .. fields)
  end
  if not channel then
    return nil
  end

  channel, number, value = tonumber(channel), tonumber(number), tonumber(value)
  if command == "on" or command == "note-on" then
    return { type = "note", channel = channel, number = number, value = value }
  elseif command == "off" or command == "note-off" then
    return { type = "note", channel = channel, number = number, value = 0 }
  elseif command == "cc" or command == "control-change" then
    return { type = "cc", channel = channel, number = number, value = value }
  end
end

function M.parse_line(line, backend)
  backend = backend or (config and effective_backend()) or "amidi"
  if backend == "receivemidi" then
    return M.parse_receivemidi_line(line)
  end
  return M.parse_amidi_line(line)
end

local function dispatch_line(line)
  local message = M.parse_line(line, effective_backend())
  if not message then
    return
  end
  local events = controller.handle(message)
  for _, event in ipairs(events) do
    vim.schedule(function()
      if event.type == "press" and handlers.on_press then
        handlers.on_press(event.index)
      elseif event.type == "turn" and handlers.on_turn then
        handlers.on_turn(event.index, event.delta)
      end
    end)
  end
end

local function consume_stdout(data)
  stdout_buffer = stdout_buffer .. data
  while true do
    local newline = stdout_buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = stdout_buffer:sub(1, newline - 1):gsub("\r$", "")
    stdout_buffer = stdout_buffer:sub(newline + 1)
    dispatch_line(line)
  end

  -- amidi prefixes a MIDI packet with a newline rather than reliably writing
  -- one after it. Dispatch a complete three-byte channel message immediately
  -- instead of retaining it until the next physical interaction supplies the
  -- next newline.
  if effective_backend() == "amidi"
    and stdout_buffer:match("^%s*%x%x%s+%x%x%s+%x%x%s*$")
  then
    local line = stdout_buffer
    stdout_buffer = ""
    dispatch_line(line)
  end
end

local function close_reconnect_timer()
  if reconnect_timer then
    reconnect_timer:stop()
    if not reconnect_timer:is_closing() then
      reconnect_timer:close()
    end
    reconnect_timer = nil
  end
end

local connect

local function schedule_reconnect()
  close_reconnect_timer()
  if not state.desired or not config.midi.reconnect then
    return
  end
  reconnect_timer = vim.uv.new_timer()
  reconnect_timer:start(config.midi.reconnect_interval_ms, 0, vim.schedule_wrap(function()
    close_reconnect_timer()
    connect()
  end))
end

local function start_reader(port, device)
  generation = generation + 1
  local reader_generation = generation
  stdout_buffer, stderr_buffer = "", ""
  set_status("connected", { port = port, device = device })

  process = vim.system(command_with(unpack(backend_args("read", port))), {
    text = true,
    stdout = function(err, data)
      if reader_generation ~= generation then
        return
      end
      if err then
        stderr_buffer = stderr_buffer .. tostring(err)
      elseif data then
        consume_stdout(data)
      end
    end,
    stderr = function(_, data)
      if reader_generation == generation and data then
        stderr_buffer = stderr_buffer .. data
      end
    end,
  }, function(result)
    vim.schedule(function()
      if reader_generation ~= generation then
        return
      end
      process = nil
      if stdout_buffer ~= "" then
        dispatch_line(stdout_buffer)
        stdout_buffer = ""
      end
      if not state.desired then
        set_status("stopped")
        return
      end
      local reason = vim.trim(stderr_buffer)
      if reason == "" then
        reason = effective_backend() .. " exited with code " .. tostring(result.code)
      end
      set_status("disconnected", { error = reason })
      notify("MIDI disconnected: " .. reason, vim.log.levels.WARN)
      schedule_reconnect()
    end)
  end)
end

local function select_device(devices)
  local matches = matching_devices(devices)
  if #matches == 1 then
    return matches[1]
  elseif #matches == 0 then
    return nil, "no matching MIDI input found"
  end
  local names = vim.tbl_map(function(device)
    return string.format("%s (%s)", device.name, device.port)
  end, matches)
  return nil, "multiple MIDI inputs matched: " .. table.concat(names, ", ")
end

connect = function()
  if not state.desired or process or state.status == "scanning" then
    return
  end
  close_reconnect_timer()

  if config.midi.port ~= "auto" then
    start_reader(config.midi.port, { port = config.midi.port, name = config.midi.port })
    return
  end

  set_status("scanning")
  local discovery_generation = generation
  M.list_devices(function(devices, list_error)
    if not state.desired or discovery_generation ~= generation then
      return
    end
    if not devices then
      set_status("disconnected", { error = list_error })
      schedule_reconnect()
      return
    end
    local device, selection_error = select_device(devices)
    if not device then
      set_status("disconnected", { error = selection_error })
      schedule_reconnect()
      return
    end
    start_reader(device.port, device)
  end)
end

function M.setup(opts, compiled_controller, callbacks)
  M.stop()
  config = opts
  controller = compiled_controller
  handlers = callbacks or {}
  set_status("stopped")
end

function M.start()
  if not config or not controller then
    error("knobby: MIDI backend is not configured")
  end
  if state.desired then
    return
  end
  state.desired = true
  controller.reset()
  connect()
end

function M.stop()
  state.desired = false
  generation = generation + 1
  close_reconnect_timer()
  if process then
    pcall(process.kill, process, 15)
    process = nil
  end
  if controller then
    controller.reset()
  end
  set_status("stopped")
end

function M.reconnect()
  if not config then
    return
  end
  M.stop()
  state.desired = true
  controller.reset()
  connect()
end

function M.status()
  return vim.deepcopy(state)
end

function M.effective_match()
  return effective_match()
end

function M.backend()
  return config and effective_backend() or nil
end

function M.command()
  return config and vim.deepcopy(config_module.effective_command(config)) or nil
end

return M
