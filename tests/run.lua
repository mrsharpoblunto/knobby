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

-- Coordination is enabled by default and its endpoint is derived from the
-- current user plus the scope, so an unscoped test instance joins whatever
-- Knobby broker is already running on the machine -- typically the developer's
-- own Neovim -- and reads that broker's real controller instead of the fake
-- MIDI command configured here. Every test opts out unless it is specifically
-- exercising coordination.
local function setup(options)
  return require("knobby").setup(vim.tbl_deep_extend("keep", options, {
    coordination = { enabled = false },
  }))
end

-- Fixtures cold-start a whole Neovim before emitting their first MIDI byte.
-- That costs a few hundred milliseconds on an idle developer machine and can
-- cost several seconds on a loaded CI runner, so these budgets are generous;
-- they only delay a run that is already failing.
local SPAWN_WAIT = 10000
local COORDINATION_WAIT = 8000
local FAILOVER_WAIT = 15000

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
    "MIDI input ports:\n[0] Grid\n1: Network Session 1\n",
    "receivemidi"
  )
  equal(vim.tbl_map(function(device)
    return device.name
  end, devices), { "Grid", "Network Session 1" })

  equal(midi.parse_line("channel  1   note-on           35 127", "receivemidi"), {
    type = "note",
    channel = 1,
    number = 35,
    value = 127,
  })
  equal(midi.parse_line("channel  1   note-off          35   0", "receivemidi"), {
    type = "note",
    channel = 1,
    number = 35,
    value = 0,
  })
  equal(midi.parse_line("channel  1   control-change    35  65", "receivemidi"), {
    type = "cc",
    channel = 1,
    number = 35,
    value = 65,
  })

  -- Keep accepting the abbreviated format emitted by older releases and
  -- existing custom wrappers around ReceiveMIDI.
  equal(midi.parse_line("ch 1 cc 35 63", "receivemidi"), {
    type = "cc",
    channel = 1,
    number = 35,
    value = 63,
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
  local knobby = setup({
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
  local knobby = setup({
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
  local knobby = setup({
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
  local knobby = setup({
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

  local knobby = setup({
    midi = {
      enabled = true,
      backend = "amidi",
      command = fake_midi_command("amidi_stream"),
      port = "fake",
      reconnect = false,
    },
    ui = { notifications = false },
  })

  assert(vim.wait(SPAWN_WAIT, function()
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

  local knobby = setup({
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

  assert(vim.wait(SPAWN_WAIT, function()
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

  local knobby = setup({
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
  assert(vim.wait(SPAWN_WAIT, function()
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

  local knobby = setup({
    midi = {
      enabled = true,
      backend = "receivemidi",
      command = fake_midi_command("receivemidi_stream"),
      reconnect = false,
    },
    controller = { profile = "intech_en16_binary_offset" },
    ui = { notifications = false },
  })

  assert(vim.wait(SPAWN_WAIT, function()
    return vim.api.nvim_buf_get_lines(buffer, 0, 1, true)[1] == "value = 1.01"
  end), "timed out waiting for streamed ReceiveMIDI events")
  equal(#knobby.status().captures, 1)
  equal(knobby.status().midi.backend, "receivemidi")
  vim.cmd("KnobbyDisable")
  knobby.release()
end)

test("coordinates active routing and broker failover across Neovim instances", function()
  local directory = vim.fn.tempname()
  assert(vim.fn.mkdir(directory, "p") == 1, "unable to create coordination test directory")
  local unique = string.format("%d%x", vim.uv.os_getpid(), vim.uv.hrtime() % 0xFFFFFF)
  local scope = "test" .. unique
  local address = directory .. "/broker.sock"
  if vim.uv.os_uname().sysname:match("^Windows") then
    address = "\\\\.\\pipe\\knobby-test-" .. unique
  end

  local function path(name)
    return directory .. "/" .. name
  end

  local function signal(label, action)
    vim.fn.writefile({ "" }, path(label .. "." .. action))
  end

  local function read_state(label)
    local ok, lines = pcall(vim.fn.readfile, path(label .. ".state"))
    if not ok or not lines[1] then
      return nil
    end
    local decoded, value = pcall(vim.json.decode, lines[1])
    return decoded and value or nil
  end

  local fixture = vim.fn.fnamemodify("tests/coordinated_instance.lua", ":p")
  local minimal = vim.fn.fnamemodify("tests/minimal_init.lua", ":p")
  local processes = {}
  local function spawn(label)
    local process = vim.system({
      vim.v.progpath,
      "--clean",
      "--headless",
      "-u",
      minimal,
      "-l",
      fixture,
      label,
      address,
      scope,
      directory,
    }, { text = true })
    processes[label] = process
    return process
  end

  local function stop_processes()
    for label in pairs(processes) do
      signal(label, "quit")
    end
    for _, process in pairs(processes) do
      local ok, result = pcall(process.wait, process, 2000)
      if not ok or not result or result.code == 124 then
        pcall(process.kill, process, 15)
        pcall(process.wait, process, 1000)
      end
    end
    vim.fn.delete(directory, "rf")
  end

  local ok, failure = xpcall(function()
    spawn("a")
    spawn("b")

    assert(vim.wait(FAILOVER_WAIT, function()
      local a, b = read_state("a"), read_state("b")
      return a
        and b
        and a.coordination.status == "connected"
        and b.coordination.status == "connected"
        and a.coordination.clients == 2
        and b.coordination.clients == 2
    end, 20), "two Knobby instances did not connect to one broker")

    assert(vim.wait(COORDINATION_WAIT, function()
      local lines = vim.fn.filereadable(path("opens.log")) == 1
          and vim.fn.readfile(path("opens.log"))
        or {}
      return #lines >= 1
    end, 20), "the broker did not start a MIDI reader")
    equal(#vim.fn.readfile(path("opens.log")), 1, "more than one MIDI reader started")

    signal("a", "activate")
    assert(vim.wait(COORDINATION_WAIT, function()
      local a, b = read_state("a"), read_state("b")
      return a and b and a.coordination.active and not b.coordination.active
    end, 20), "instance A did not become active")
    vim.fn.writefile({ "press_turn" }, path("midi.trigger"))
    assert(vim.wait(COORDINATION_WAIT, function()
      local a = read_state("a")
      return a and a.value == "value = 1.01"
    end, 20), "MIDI was not routed to active instance A")
    equal(read_state("b").value, "value = 2.00", "inactive instance B was edited")

    signal("b", "activate")
    assert(vim.wait(COORDINATION_WAIT, function()
      local a, b = read_state("a"), read_state("b")
      return a and b and not a.coordination.active and b.coordination.active
    end, 20), "instance B did not take activation")
    vim.fn.writefile({ "press_turn" }, path("midi.trigger"))
    assert(vim.wait(COORDINATION_WAIT, function()
      local b = read_state("b")
      return b and b.value == "value = 2.01"
    end, 20), "MIDI was not routed to active instance B")
    equal(read_state("a").value, "value = 1.01", "inactive instance A was edited")

    local a, b = read_state("a"), read_state("b")
    local broker_label = a.coordination.role == "broker" and "a" or "b"
    local survivor_label = broker_label == "a" and "b" or "a"
    signal(survivor_label, "activate")
    assert(vim.wait(COORDINATION_WAIT, function()
      local survivor = read_state(survivor_label)
      return survivor and survivor.coordination.active
    end, 20), "the surviving instance did not become active")

    signal(broker_label, "quit")
    local broker_result = processes[broker_label]:wait(COORDINATION_WAIT)
    assert(broker_result.code == 0, broker_result.stderr or "broker fixture failed")
    processes[broker_label] = nil

    assert(vim.wait(FAILOVER_WAIT, function()
      local survivor = read_state(survivor_label)
      return survivor
        and survivor.coordination.role == "broker"
        and survivor.coordination.status == "connected"
        and survivor.coordination.active
    end, 20), "the surviving instance did not take over the broker role")
    assert(vim.wait(COORDINATION_WAIT, function()
      return vim.fn.filereadable(path("opens.log")) == 1
        and #vim.fn.readfile(path("opens.log")) == 2
    end, 20), "broker failover did not start exactly one replacement MIDI reader")

    vim.fn.writefile({ "turn" }, path("midi.trigger"))
    local expected = survivor_label == "a" and "value = 1.02" or "value = 2.02"
    assert(vim.wait(COORDINATION_WAIT, function()
      local survivor = read_state(survivor_label)
      return survivor and survivor.value == expected
    end, 20), "MIDI routing did not survive broker failover")
  end, debug.traceback)

  stop_processes()
  if not ok then
    error(failure)
  end
end)

if #failures > 0 then
  error(string.format("%d test(s) failed:\n\n%s", #failures, table.concat(failures, "\n\n")))
end

print(string.format("%d tests passed", passed))
vim.cmd("qa!")
