local failures = {}
local passed = 0

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
      command = { "sh", "-c", "printf '90 20 7F\\n'; sleep 0.06; printf 'B0 20 01\\n'" },
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
      command = {
        "sh",
        "-c",
        "printf '\\n90 20 7F'; sleep 0.06; printf '\\nB0 20 41'; sleep 1",
      },
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
      command = {
        "sh",
        "-c",
        "printf '90 20 7F\\n'; sleep 0.06; printf 'B0 20 01\\n'; sleep 0.06; printf 'B0 20 02\\n90 20 7F\\n'",
      },
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

if #failures > 0 then
  error(string.format("%d test(s) failed:\n\n%s", #failures, table.concat(failures, "\n\n")))
end

print(string.format("%d tests passed", passed))
vim.cmd("qa!")
