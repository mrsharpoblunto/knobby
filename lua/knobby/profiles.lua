local M = {}

local function intech_en16_profile(rotary)
  return {
    device_match = {
      usb_id = "303a:8123",
      name = "^Grid MIDI",
      card = "Grid",
    },
    channel = 1,
    controls = {
      count = 16,
      turn = {
        message = "cc",
        first_number = 32,
      },
      press = {
        message = "note",
        first_number = 32,
        minimum_velocity = 1,
      },
      rotary = rotary,
    },
  }
end

local builtins = {
  -- Knobby assigns an encoder to arbitrary document values, so the EN16 must
  -- report direction and distance rather than a bounded controller value.
  intech_en16 = intech_en16_profile({
    encoding = "twos_complement",
  }),
  intech_en16_binary_offset = intech_en16_profile({
    encoding = "binary_offset",
  }),
  custom = {
    channel = 1,
    controls = {},
  },
}

local function event_key(message, number, channel)
  return table.concat({ message, number, channel or "any" }, ":")
end

local function normalized_controls(profile)
  local controls = profile.controls or {}
  if controls[1] ~= nil then
    return vim.deepcopy(controls)
  end

  local result = {}
  for index = 1, controls.count or 0 do
    local turn = vim.deepcopy(controls.turn or {})
    local press = vim.deepcopy(controls.press or {})
    if turn.first_number ~= nil then
      turn.number = turn.first_number + index - 1
      turn.first_number = nil
    end
    if press.first_number ~= nil then
      press.number = press.first_number + index - 1
      press.first_number = nil
    end
    result[index] = {
      index = index,
      turn = turn,
      press = press,
      rotary = vim.deepcopy(controls.rotary or {}),
    }
  end
  return result
end

local function decode_absolute_wrap(value, previous, opts)
  local modulus = opts.modulus or 128
  if previous == nil then
    previous = opts.initial_value
    if previous == nil then
      return 0, value
    end
  end

  local delta = (value - previous) % modulus
  if delta > modulus / 2 then
    delta = delta - modulus
  end
  if opts.maximum_jump and math.abs(delta) > opts.maximum_jump then
    delta = 0
  end
  return delta, value
end

local decoders = {
  absolute_wrap = decode_absolute_wrap,
  twos_complement = function(value)
    return value < 64 and value or value - 128, value
  end,
  binary_offset = function(value)
    return value - 64, value
  end,
  sign_magnitude = function(value)
    if value == 64 or value == 0 then
      return 0, value
    end
    return value < 64 and value or -(value - 64), value
  end,
  inc_dec = function(value)
    if value == 1 then
      return 1, value
    elseif value == 127 then
      return -1, value
    end
    return 0, value
  end,
}

function M.decode_rotary(value, previous, opts)
  opts = opts or {}
  local encoding = opts.encoding or "absolute_wrap"
  if type(encoding) == "function" then
    local delta = encoding(value, previous, opts)
    return delta or 0, value
  end
  local decoder = decoders[encoding]
  if not decoder then
    error("knobby: unknown rotary encoding: " .. tostring(encoding))
  end
  return decoder(value, previous, opts)
end

local function resolve_profile(controller)
  local builtin = builtins[controller.profile]
  if not builtin then
    error("knobby: unknown controller profile: " .. tostring(controller.profile))
  end
  return vim.tbl_deep_extend("force", vim.deepcopy(builtin), controller)
end

function M.compile(controller)
  local profile = resolve_profile(controller)
  local button_map = {}
  local turn_map = {}
  local previous = {}
  local controls = normalized_controls(profile)
  local maximum_index = 0

  for _, control in ipairs(controls) do
    local index = assert(control.index, "knobby: every control requires an index")
    maximum_index = math.max(maximum_index, index)
    local channel = control.channel or profile.channel or "any"
    if control.press and control.press.number ~= nil then
      local message = control.press.message or "note"
      button_map[event_key(message, control.press.number, control.press.channel or channel)] = control
    end
    if control.turn and control.turn.number ~= nil then
      local message = control.turn.message or "cc"
      turn_map[event_key(message, control.turn.number, control.turn.channel or channel)] = control
    end
  end

  local compiled = {
    name = controller.profile,
    device_match = profile.device_match or {},
    count = maximum_index,
    controls = controls,
  }

  local function lookup(map, message)
    return map[event_key(message.type, message.number, message.channel)]
      or map[event_key(message.type, message.number, "any")]
  end

  function compiled.handle(message)
    local events = {}
    local press_control = lookup(button_map, message)
    if press_control then
      local press = press_control.press
      local pressed
      if press.message == "note" then
        pressed = message.type == "note" and message.value >= (press.minimum_velocity or 1)
      elseif press.pressed_value ~= nil then
        pressed = message.value == press.pressed_value
      else
        pressed = message.value >= (press.minimum_value or 1)
      end
      if pressed then
        events[#events + 1] = { type = "press", index = press_control.index }
      end
    end

    local turn_control = lookup(turn_map, message)
    if turn_control then
      local rotary = vim.tbl_deep_extend(
        "force",
        vim.deepcopy(profile.controls.rotary or {}),
        turn_control.rotary or {}
      )
      local delta, next_value = M.decode_rotary(message.value, previous[turn_control.index], rotary)
      previous[turn_control.index] = next_value
      if delta ~= 0 then
        events[#events + 1] = { type = "turn", index = turn_control.index, delta = delta }
      end
    end
    return events
  end

  function compiled.reset()
    previous = {}
  end

  return compiled
end

function M.names()
  return vim.tbl_keys(builtins)
end

return M
