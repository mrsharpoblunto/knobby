local failures = {}
local passed = 0

local function fake_midi_command(scenario)
  return {
    vim.v.progpath,
    "--clean",
    "--headless",
    "-u",
    "NONE",
    "-l",
    vim.fn.fnamemodify("tests/fake_midi.lua", ":p"),
    scenario,
  }
end

local function equal(actual, expected, context)
  if not vim.deep_equal(actual, expected) then
    error(string.format(
      "%s\nexpected: %s\nactual:   %s",
      context or "values differ",
      vim.inspect(expected),
      vim.inspect(actual)
    ))
  end
end

local function test(name, callback)
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    passed = passed + 1
    print("ok - " .. name)
  else
    failures[#failures + 1] = name .. "\n" .. err
    print("not ok - " .. name)
  end
end

test("finds signed decimal and scientific tokens", function()
  local numbers = require("knobby.numbers")
  local tokens = numbers.find_all("x=-12.50 y=.25 z=1.2e3")
  equal(vim.tbl_map(function(token)
    return token.text
  end, tokens), { "-12.50", ".25", "1.2e3" })
  equal(tokens[1].step_exponent, -2)
  equal(tokens[3].step_exponent, 2)
end)

test("increments decimals exactly and preserves formatting", function()
  local numbers = require("knobby.numbers")
  equal(numbers.increment("1.20", -2, 1), "1.21")
  equal(numbers.increment("1.20", -2, -1), "1.19")
  equal(numbers.increment("0.00", -2, -1), "-0.01")
  equal(numbers.increment("1.20", -3, 1), "1.201")
  equal(numbers.increment("-0.10", -1, 1), "0.00")
  equal(numbers.increment("+007", 0, 1), "+008")
  equal(numbers.increment("999999999999999999999999", 0, 1), "1000000000000000000000000")
  equal(numbers.increment("1.2e3", 2, 1), "1.3e3")
end)

test("decodes the EN16 profile", function()
  local midi = require("knobby.midi")
  local profile = require("knobby.profiles").compile({ profile = "intech_en16" })
  equal(profile.handle(assert(midi.parse_line("90 23 7F"))), { { type = "press", index = 4 } })
  equal(profile.handle(assert(midi.parse_line("90 23 00"))), {})
  equal(profile.handle(assert(midi.parse_line("B0 23 01"))), { { type = "turn", index = 4, delta = 1 } })
  equal(profile.handle(assert(midi.parse_line("B0 23 7F"))), { { type = "turn", index = 4, delta = -1 } })
end)

test("selects the native MIDI backend for each supported platform", function()
  local config = require("knobby.config")
  equal(config.platform_backend("Darwin"), "receivemidi")
  equal(config.platform_backend("Linux"), "amidi")
  equal(config.platform_backend("Windows_NT"), "receivemidi")
  equal(config.default_command("receivemidi", "Darwin"), "receivemidi")
  equal(config.default_command("receivemidi", "Windows_NT"), "receivemidi.exe")
  local sysname = vim.uv.os_uname().sysname
  equal(
    config.platform_backend(),
    (sysname == "Darwin" or sysname:match("^Windows")) and "receivemidi" or "amidi"
  )
  local receive_config = config.resolve({ midi = { backend = "receivemidi" } })
  equal(config.effective_command(receive_config), config.default_command("receivemidi"))
end)

test("parses ReceiveMIDI ports and controller messages", function()
  local midi = require("knobby.midi")
  local devices = midi.parse_devices(
    "MIDI input ports:\n[0] Grid MIDI\n1: Network Session 1\n",
    "receivemidi"
  )
  equal(vim.tbl_map(function(device)
    return device.name
  end, devices), { "Grid MIDI", "Network Session 1" })

  equal(midi.parse_line("ch 1 on 35 127", "receivemidi"), {
    type = "note",
    channel = 1,
    number = 35,
    value = 127,
  })
  equal(midi.parse_line("ch 1 off 35 64", "receivemidi"), {
    type = "note",
    channel = 1,
    number = 35,
    value = 0,
  })
  equal(midi.parse_line("ch 1 cc 35 65", "receivemidi"), {
    type = "cc",
    channel = 1,
    number = 35,
    value = 65,
  })
end)

test("decodes repeated EN16 relative turns", function()
  local midi = require("knobby.midi")
  local twos = require("knobby.profiles").compile({
    profile = "intech_en16",
  })
  equal(twos.handle(assert(midi.parse_line("B0 23 7F"))), { { type = "turn", index = 4, delta = -1 } })
  equal(twos.handle(assert(midi.parse_line("B0 23 7F"))), { { type = "turn", index = 4, delta = -1 } })
  equal(twos.handle(assert(midi.parse_line("B0 23 01"))), { { type = "turn", index = 4, delta = 1 } })
  equal(twos.handle(assert(midi.parse_line("B0 23 01"))), { { type = "turn", index = 4, delta = 1 } })

  local offset = require("knobby.profiles").compile({
    profile = "intech_en16_binary_offset",
  })
  equal(offset.handle(assert(midi.parse_line("B0 23 3F"))), { { type = "turn", index = 4, delta = -1 } })
  equal(offset.handle(assert(midi.parse_line("B0 23 41"))), { { type = "turn", index = 4, delta = 1 } })
end)

test("supports explicit noncontiguous controller mappings", function()
  local midi = require("knobby.midi")
  local profile = require("knobby.profiles").compile({
    profile = "custom",
    controls = {
      {
        index = 1,
        turn = { message = "cc", number = 74 },
        press = { message = "note", number = 48 },
        rotary = { encoding = "inc_dec" },
      },
    },
  })
  equal(profile.handle(assert(midi.parse_line("90 30 7F"))), { { type = "press", index = 1 } })
  equal(profile.handle(assert(midi.parse_line("B0 4A 7F"))), { { type = "turn", index = 1, delta = -1 } })
end)

test("captures, tracks, steps, and releases a number", function()
  local knobby = require("knobby").setup({
    midi = { enabled = false },
    ui = { notifications = false },
  })
  local buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "local value = 1.20", "other = 7" })
  vim.api.nvim_win_set_cursor(0, { 1, 15 })

  assert(knobby.toggle(4))
  equal(#knobby.status().captures, 1)
  assert(knobby.turn(4, -1))
  equal(vim.api.nvim_buf_get_lines(buffer, 0, 1, true)[1], "local value = 1.19")
  assert(knobby.turn(4, 1))
  equal(vim.api.nvim_buf_get_lines(buffer, 0, 1, true)[1], "local value = 1.20")

  vim.api.nvim_buf_set_lines(buffer, 0, 0, false, { "-- shifted" })
  vim.wait(20)
  assert(knobby.turn(4, 1))
  equal(vim.api.nvim_buf_get_lines(buffer, 1, 2, true)[1], "local value = 1.21")

  vim.api.nvim_win_set_cursor(0, { 2, 15 })
  assert(knobby.step_up())
  assert(knobby.turn(4, 1))
  equal(vim.api.nvim_buf_get_lines(buffer, 1, 2, true)[1], "local value = 1.31")

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  assert(knobby.toggle(4))
  equal(#knobby.status().captures, 0)
end)

test("routes optional navigation and step encoder roles", function()
  local knobby = require("knobby").setup({
    midi = { enabled = false },
    controller = {
      roles = {
        navigation = { index = 16, captured_only = false, wrap = true },
        step = { index = 15, reset_on_press = true },
      },
    },
    ui = { notifications = false },
  })
  local buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buffer)
  local line = "a = 1.0; b = 2; c = 3.00"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { line })
  local tokens = require("knobby.numbers").find_all(line)
  vim.api.nvim_win_set_cursor(0, { 1, tokens[1].start_col })
  assert(knobby.toggle(1))

  assert(knobby.turn(16, 1))
  equal(vim.api.nvim_win_get_cursor(0), { 1, tokens[2].start_col })

  local toggled, captured_only = knobby.press(16)
  equal(toggled, true)
  equal(captured_only, true)
  assert(knobby.turn(16, 1))
  equal(vim.api.nvim_win_get_cursor(0), { 1, tokens[1].start_col })

  assert(knobby.turn(15, 1))
  equal(knobby.status().captures[1].step, "1")
  assert(knobby.press(15))
  equal(knobby.status().captures[1].step, "0.1")
  equal(#knobby.status().captures, 1)

  local _, all_values = knobby.press(16)
  equal(all_values, false)
  assert(knobby.turn(16, -1))
  equal(vim.api.nvim_win_get_cursor(0), { 1, tokens[3].start_col })
  equal(knobby.status().roles.navigation.captured_only, false)
  equal(knobby.status().roles.step.index, 15)
  knobby.release()
end)

test("rejects conflicting special encoder roles", function()
  local ok, err = pcall(require("knobby.config").resolve, {
    controller = {
      roles = {
        navigation = { index = 16 },
        step = { index = 16 },
      },
    },
  })
  equal(ok, false)
  assert(tostring(err):match("cannot have both"), tostring(err))
end)

test("rejects duplicate captures", function()
  local knobby = require("knobby").setup({
    midi = { enabled = false },
    ui = { notifications = false },
  })
  local buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "x = 42" })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  assert(knobby.toggle(1))
  local ok, reason = knobby.toggle(2)
  equal(ok, false)
  equal(reason, "number is already captured")
  knobby.release()
end)

test("releases a deleted captured number", function()
  local knobby = require("knobby").setup({
    midi = { enabled = false },
    ui = { notifications = false },
  })
  local buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "x = 42" })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  assert(knobby.toggle(1))
  vim.api.nvim_buf_set_text(buffer, 0, 4, 0, 6, { "" })
  local ok = knobby.turn(1, 1)
  equal(ok, false)
  equal(#knobby.status().captures, 0)
end)

test("streams amidi events through the complete plugin", function()
  local buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "value = 1.00" })
  vim.api.nvim_win_set_cursor(0, { 1, 9 })

  local knobby = require("knobby").setup({
    midi = {
      enabled = true,
      backend = "amidi",
      command = fake_midi_command("amidi_stream"),
      port = "fake",
      reconnect = false,
    },
    ui = { notifications = false },
  })

  assert(vim.wait(1000, function()
    return vim.api.nvim_buf_get_lines(buffer, 0, 1, true)[1] == "value = 1.01"
  end), "timed out waiting for streamed MIDI events")
  equal(#knobby.status().captures, 1)
  vim.cmd("KnobbyDisable")
  knobby.release()
end)

test("dispatches amidi packets without waiting for the next leading newline", function()
  local buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "value = 1.00" })
  vim.api.nvim_win_set_cursor(0, { 1, 9 })

  local knobby = require("knobby").setup({
    midi = {
      enabled = true,
      backend = "amidi",
      command = fake_midi_command("amidi_unterminated"),
      port = "fake",
      reconnect = false,
    },
    controller = { profile = "intech_en16_binary_offset" },
    ui = { notifications = false },
  })

  assert(vim.wait(500, function()
    return vim.api.nvim_buf_get_lines(buffer, 0, 1, true)[1] == "value = 1.01"
  end), "timed out waiting for an unterminated amidi packet")
  vim.cmd("KnobbyDisable")
  knobby.release()
end)

test("button press cancels a pending push-induced turn", function()
  local buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "value = 1.00" })
  vim.api.nvim_win_set_cursor(0, { 1, 9 })

  local knobby = require("knobby").setup({
    midi = {
      enabled = true,
      backend = "amidi",
      command = fake_midi_command("amidi_button_guard"),
      port = "fake",
      reconnect = false,
    },
    ui = { notifications = false },
  })

  local saw_capture = false
  assert(vim.wait(1000, function()
    local count = #knobby.status().captures
    saw_capture = saw_capture or count > 0
    return saw_capture and count == 0
  end), "timed out waiting for the release event")
  equal(vim.api.nvim_buf_get_lines(buffer, 0, 1, true)[1], "value = 1.01")
  vim.cmd("KnobbyDisable")
end)

test("streams ReceiveMIDI events through the complete plugin", function()
  local buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "value = 1.00" })
  vim.api.nvim_win_set_cursor(0, { 1, 9 })

  local knobby = require("knobby").setup({
    midi = {
      enabled = true,
      backend = "receivemidi",
      command = fake_midi_command("receivemidi_stream"),
      reconnect = false,
    },
    controller = { profile = "intech_en16_binary_offset" },
    ui = { notifications = false },
  })

  assert(vim.wait(1000, function()
    return vim.api.nvim_buf_get_lines(buffer, 0, 1, true)[1] == "value = 1.01"
  end), "timed out waiting for streamed ReceiveMIDI events")
  equal(#knobby.status().captures, 1)
  equal(knobby.status().midi.backend, "receivemidi")
  vim.cmd("KnobbyDisable")
  knobby.release()
end)

if #failures > 0 then
  error(string.format("%d test(s) failed:\n\n%s", #failures, table.concat(failures, "\n\n")))
end

print(string.format("%d tests passed", passed))
vim.cmd("qa!")
