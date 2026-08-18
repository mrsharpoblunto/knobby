local scenario, command, port, mode = unpack(arg)

local function emit(data)
  io.stdout:write(data)
  io.stdout:flush()
end

local function pause(milliseconds)
  vim.uv.sleep(milliseconds)
end

if scenario == "amidi_stream" then
  emit("90 20 7F\n")
  pause(60)
  emit("B0 20 01\n")
elseif scenario == "amidi_unterminated" then
  emit("\n90 20 7F")
  pause(60)
  emit("\nB0 20 41")
  pause(1000)
elseif scenario == "amidi_button_guard" then
  emit("90 20 7F\n")
  pause(60)
  emit("B0 20 01\n")
  pause(60)
  emit("B0 20 02\n90 20 7F\n")
elseif scenario == "receivemidi_stream" and command == "list" then
  emit("Grid MIDI\n")
elseif scenario == "receivemidi_stream"
  and command == "dev"
  and port == "Grid MIDI"
  and mode == "nn"
then
  emit("ch 1 on 32 127\n")
  pause(60)
  emit("ch 1 cc 32 65\n")
else
  io.stderr:write("unexpected fake MIDI invocation\n")
  io.stderr:flush()
  vim.cmd("cquit 9")
  return
end

vim.cmd("qa!")
