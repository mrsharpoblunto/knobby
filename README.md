# Knobby

[![CI](https://github.com/mrsharpoblunto/knobby/actions/workflows/ci.yml/badge.svg)](https://github.com/mrsharpoblunto/knobby/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Knobby captures numbers in Neovim buffers and lets physical rotary encoders
edit them. Press an encoder button while the cursor is on a number to capture
it; press the same button anywhere to release it.

Captured ranges are stored as Neovim extmarks, so they follow insertions,
deletions, line changes, and undo operations. Knobby highlights each captured
number and displays its encoder and step inline:

```text
timeout = 42.75 ⟦E4 ±0.01⟧
```

## Requirements

- Neovim 0.10 or newer
- `amidi` from `alsa-utils`
- A MIDI controller visible as an ALSA raw MIDI input

## Installation

### lazy.nvim

Add this entry to the plugin-spec table passed to Lazy:

```lua
{
  "mrsharpoblunto/knobby",
  lazy = false,
  opts = {},
}
```

Lazy infers the `knobby` Lua module and calls `setup()` with `opts`.

For local development, register the working tree as a local plugin instead of
prepending it to `runtimepath` before `lazy.setup()`:

```lua
{
  dir = "/home/gconner/dev/knobby",
  name = "knobby",
  lazy = false,
  opts = {},
}
```

Remove any earlier manual `runtimepath:prepend()` and `setup()` calls from
`init.lua`. Lazy will add the complete plugin directory to `runtimepath`, which
is required for runtime features such as `:checkhealth knobby` discovery.

### Native packages

Clone Knobby into Neovim's native `start` package directory:

```bash
git clone https://github.com/mrsharpoblunto/knobby.git \
  ~/.local/share/nvim/site/pack/plugins/start/knobby
```

Then configure it in `init.lua`:

```lua
require("knobby").setup()
```

Other plugin managers can install `mrsharpoblunto/knobby` as a standard
runtimepath plugin; call `require("knobby").setup()` in their configuration
hook.

## Configuration

Call `setup()` from `init.lua` or your plugin manager:

```lua
require("knobby").setup({
  midi = {
    backend = "amidi",
    line_buffered = true,
    port = "auto",
    match = {
      usb_id = "303a:8123",
      name = "^Grid MIDI",
      -- serial = "123456",
    },
    reconnect = true,
  },

  controller = {
    -- Requires Encoder Mode 2 (2's Complement) in Grid Editor.
    profile = "intech_en16",
    turn_flush_ms = 8,
    button_guard_ms = 25,
    roles = {
      navigation = {
        index = false,
        captured_only = false,
        wrap = true,
      },
      step = {
        index = false,
        reset_on_press = true,
      },
    },
  },

  keys = {
    step_down = "[k",
    step_up = "]k",
    step_reset = false,
  },
})
```

The EN16 profiles map channel 1 CC and note numbers 32 through 47 to encoders
1 through 16. Grid Editor configurations can change those messages; use a
custom controller mapping when needed.

Knobby uses the EN16 as an unbounded relative controller. The Grid factory
default is Absolute encoder mode, which stops at `0` and `127` and is not
supported by the EN16 profile. In Grid Editor, add an **Encoder Mode** action to
each encoder's Setup event and select mode **2 — 2's Complement**.

Available EN16 profiles are:

```text
intech_en16                  Relative mode 2 (2's Complement); default
intech_en16_binary_offset    Relative mode 1 (Binary Offset)
```

Turns are accumulated briefly for `turn_flush_ms` before being applied. A
button press discards the most recent pending turn inside `button_guard_ms`,
applies any earlier movement, and briefly suppresses new rotation. This
prevents a push-induced encoder tick from changing a value immediately before
capture or release without swallowing a legitimate batch of turns. Both
timings are configurable.

### Special encoder roles

Encoders can optionally be reserved for navigation and step adjustment. For
example, this assigns encoder 16 to numeric navigation and encoder 15 to step
size:

```lua
require("knobby").setup({
  controller = {
    profile = "intech_en16_binary_offset",
    roles = {
      navigation = {
        index = 16,
        captured_only = false,
        wrap = true,
      },
      step = {
        index = 15,
        reset_on_press = true,
      },
    },
  },
})
```

Turning the navigation encoder clockwise moves to the next capturable number
in the current buffer; counterclockwise moves to the previous one. It wraps at
the beginning and end by default. Pressing it toggles between all capturable
numbers and only numbers that are currently captured. `captured_only` selects
the initial mode, and `:KnobbyStatus` shows the current mode.

Turning the step encoder clockwise multiplies the captured value's current
step by ten; counterclockwise divides it by ten. The cursor must be on a
captured number. Its button resets that number to its precision-derived step
when `reset_on_press = true`.

Both roles are disabled when their `index` is `false`. A physical encoder can
have only one special role, and role indices are reserved from normal MIDI
capture/release behavior.

### Device selection

USB/IP's Windows BUSID is not part of plugin configuration. It describes a
physical Windows USB topology and can change. Knobby discovers the ALSA device
inside WSL using its USB ID, serial, card, and MIDI name.

On the development machine, this stable explicit port also works:

```lua
require("knobby").setup({
  midi = {
    port = "hw:Grid,0,0",
  },
})
```

With `port = "auto"`, Knobby chooses a device only when exactly one device
matches. An ambiguous match is reported instead of selecting arbitrarily.
Use `:KnobbyDevices` to inspect the available identities.

`line_buffered = true` uses `stdbuf` when available so long-running `amidi`
processes deliver each MIDI event immediately instead of retaining output in a
stdio buffer.

### Custom controllers

Contiguous controls can be described compactly:

```lua
require("knobby").setup({
  controller = {
    profile = "custom",
    channel = 1,
    controls = {
      count = 8,
      turn = { message = "cc", first_number = 20 },
      press = { message = "note", first_number = 40, minimum_velocity = 1 },
      rotary = { encoding = "twos_complement" },
    },
  },
  midi = {
    match = { name = "^My Controller" },
  },
})
```

Noncontiguous message layouts use an explicit control list:

```lua
controller = {
  profile = "custom",
  controls = {
    {
      index = 1,
      turn = { message = "cc", number = 74 },
      press = { message = "note", number = 48 },
      rotary = { encoding = "inc_dec" },
    },
  },
}
```

Built-in rotary encodings are `absolute_wrap`, `twos_complement`,
`binary_offset`, `sign_magnitude`, and `inc_dec`. `encoding` may also be a
function receiving `(value, previous_value, options)` and returning a signed
delta.

### Capture behavior and UI

```lua
require("knobby").setup({
  capture = {
    duplicate = "reject",       -- or "transfer"
    invalid_number = "release", -- or "keep"
    undo_join_ms = 250,
  },
  ui = {
    highlight = "KnobbyCapture",
    label_highlight = "KnobbyLabel",
    notifications = true,
    virtual_text = {
      enabled = true,
      position = "inline",
      format = " ⟦E%d ±%s⟧",
    },
  },
})
```

The default step is the power of ten represented by the least-significant
displayed digit: `42` uses `1`, `42.0` uses `0.1`, and `42.750` uses `0.001`.
Knobby uses exact decimal string arithmetic and preserves displayed precision.

`[k` divides the step by ten and `]k` multiplies it by ten when the cursor is
on a captured number. Counts are supported, so `3]k` multiplies the step by
1000. The plugin also defines these remapping targets:

```text
<Plug>(KnobbyStepDown)
<Plug>(KnobbyStepUp)
<Plug>(KnobbyStepReset)
```

## Commands

```text
:KnobbyToggle {encoder}  Capture or release an encoder
:KnobbyRelease [encoder] Release one encoder, or all when omitted
:KnobbyStepUp            Multiply the current capture's step by ten
:KnobbyStepDown          Divide the current capture's step by ten
:KnobbyStepReset         Reset from the number's displayed precision
:KnobbyDevices           List discovered raw MIDI inputs
:KnobbyStatus            Show connection and capture state
:KnobbyReconnect         Restart MIDI discovery and input
:KnobbyEnable            Start MIDI input
:KnobbyDisable           Stop MIDI input
:checkhealth knobby      Diagnose dependencies and device access
```

For statusline plugins, `require("knobby").statusline()` returns a compact
connection and capture summary.

## Windows and WSL setup

The controller is connected to Windows, while Neovim runs inside WSL. USB/IP
passes the complete USB device through to WSL so it can be read as a native
ALSA raw MIDI device.

The controller detected during initial setup had these identifiers:

```text
Device:  Intech Grid MIDI device
USB ID:  303a:8123
BUSID:   5-8
```

`5-8` means USB bus 5, port 8; it is one address, not a range. The BUSID can
change if the controller is plugged into a different USB port, so match the
`303a:8123` USB ID and device name when running `usbipd list`.

### 1. Install USB/IP on Windows

Run in PowerShell:

```powershell
winget install --interactive --exact dorssel.usbipd-win
```

Open a new PowerShell window afterward so that `usbipd` is on `PATH`.

### 2. Share and attach the controller

In an **administrator PowerShell** window, list the devices and bind the EN16:

```powershell
usbipd list
usbipd bind --busid 5-8
```

Binding is persistent. In a regular PowerShell window, attach it to WSL:

```powershell
usbipd attach --wsl --busid 5-8
```

Attachment is not persistent across unplugging the controller, restarting
Windows, or shutting down WSL. Repeat the attach command when necessary. While
attached, the controller's composite MIDI, HID, and serial interfaces belong to
WSL rather than Windows.

### 3. Install the ALSA utilities in WSL

```bash
sudo apt update
sudo apt install alsa-utils
```

### 4. Grant MIDI device access

ALSA creates the raw MIDI endpoint as `/dev/snd/midiC0D0`, owned by the
`audio` group. Add the current WSL user to that group:

```bash
sudo usermod -aG audio "$USER"
```

The new group membership requires a fresh WSL login. From PowerShell, shut down
WSL:

```powershell
wsl --shutdown
```

Start WSL again and reattach the controller with `usbipd attach` if needed.

### 5. Verify MIDI input

In WSL, confirm that `audio` appears in the group list:

```bash
id -nG
```

Then list the raw MIDI endpoints:

```bash
amidi --list-devices
```

The EN16 should appear as an Intech Studio Grid endpoint. Use the hardware port
reported by `amidi` to dump incoming messages; during initial setup it was
`hw:0,0,0`:

```bash
amidi --port hw:0,0,0 --dump
```

Turning encoders and pressing their buttons should now print MIDI bytes. Press
`Ctrl-C` to stop the dump.

### `aconnect` limitation

The current Microsoft WSL kernel does not include the ALSA `snd-seq` module, so
`aconnect` fails because `/dev/snd/seq` does not exist. This is expected and
does not prevent Knobby from working: the plugin can consume MIDI directly from
the raw `/dev/snd/midiC*D*` endpoint. Enabling `aconnect` would require a custom
WSL kernel with ALSA sequencer support.

## Development

Run the headless test suite from the repository root:

```bash
nvim --clean --headless -u tests/minimal_init.lua -l tests/run.lua
```

Generate local help tags after editing `doc/knobby.txt` with:

```bash
nvim --clean --headless -u NONE --cmd 'helptags doc' +qa
```

## License

[MIT](LICENSE) © 2026 Glenn Conner
