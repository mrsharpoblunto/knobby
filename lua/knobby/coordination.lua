local M = {}

local uv = vim.uv
local protocol_version = 1

local config
local handlers = {}
local server
local client
local retry_timer
local heartbeat_timer
local lock_fd
local lock_path
local socket_address
local generation = 0
local peers = {}
local broker_midi_status
local wants_active = false
local instance_id

local state = {
  desired = false,
  status = "stopped",
  role = "none",
  active = false,
  active_id = nil,
  broker_id = nil,
  clients = 0,
  endpoint = nil,
  error = nil,
  midi = nil,
}

local function endpoint()
  return socket_address
end

local function is_windows()
  return uv.os_uname().sysname:match("^Windows") ~= nil
end

local function writable_directory(directory)
  if not directory or directory == "" then
    return false
  end
  pcall(vim.fn.mkdir, directory, "p")
  if not uv.fs_stat(directory) then
    return false
  end
  local ok, accessible = pcall(uv.fs_access, directory, "W")
  return ok and accessible == true
end

local function runtime_directory()
  local candidates = {}
  local ok, directory = pcall(vim.fn.stdpath, "run")
  if ok and directory ~= "" then
    -- stdpath("run") is normally an instance-specific Nvim temp directory, so
    -- the shared broker socket and lock belong in its per-user parent, where
    -- every Nvim process resolves the same endpoints. That is not guaranteed:
    -- when XDG_RUNTIME_DIR names a directory Nvim cannot create -- CI runners
    -- and containers routinely export /run/user/<uid> with no logind session
    -- behind it -- stdpath("run") is that directory itself and the parent is
    -- /run/user, which exists but is not writable. Opening the lock there
    -- fails, so no instance ever wins the election and they all retry as
    -- clients against a socket nobody bound. Take the first candidate that is
    -- actually writable.
    candidates[#candidates + 1] = vim.fs.dirname(directory)
    candidates[#candidates + 1] = directory
  end
  candidates[#candidates + 1] = vim.fn.stdpath("state")
  for _, candidate in ipairs(candidates) do
    if writable_directory(candidate) then
      return (candidate:gsub("[\\/]$", ""))
    end
  end
  return (vim.fn.stdpath("state"):gsub("[\\/]$", ""))
end

local function resolved_endpoints()
  local directory = runtime_directory()
  local user = (vim.env.USER or vim.env.USERNAME or "user"):gsub("[^%w_.-]", "_")
  local name = string.format("knobby-%s-%s", user, config.scope)
  local address = config.address
  if address == "auto" then
    if is_windows() then
      address = "\\\\.\\pipe\\" .. name
    else
      address = directory .. "/" .. name .. ".sock"
    end
  end
  return address, directory .. "/" .. name .. ".lock"
end

local function schedule_handler(name, ...)
  local callback = handlers[name]
  if not callback then
    return
  end
  local args = { ... }
  vim.schedule(function()
    callback(unpack(args))
  end)
end

local function emit_status()
  schedule_handler("on_status", vim.deepcopy(state))
end

local function set_role(role)
  if state.role == role then
    return
  end
  state.role = role
  schedule_handler("on_role", role == "broker")
end

local function set_active(active)
  if state.active == active then
    return
  end
  state.active = active
  schedule_handler("on_active", active)
end

local function close_handle(handle)
  if not handle then
    return
  end
  pcall(handle.read_stop, handle)
  if not handle:is_closing() then
    handle:close()
  end
end

local function close_retry_timer()
  if not retry_timer then
    return
  end
  retry_timer:stop()
  if not retry_timer:is_closing() then
    retry_timer:close()
  end
  retry_timer = nil
end

local function close_heartbeat_timer()
  if not heartbeat_timer then
    return
  end
  heartbeat_timer:stop()
  if not heartbeat_timer:is_closing() then
    heartbeat_timer:close()
  end
  heartbeat_timer = nil
end

local function release_lock()
  local owned = lock_fd ~= nil
  close_heartbeat_timer()
  if lock_fd then
    pcall(uv.fs_close, lock_fd)
    lock_fd = nil
  end
  if owned and lock_path then
    pcall(uv.fs_unlink, lock_path)
  end
end

local function touch_lock()
  if not lock_fd then
    return
  end
  local now = os.time()
  pcall(uv.fs_utime, lock_path, now, now)
end

local function acquire_lock()
  local fd, err = uv.fs_open(lock_path, "wx", 384)
  if not fd then
    return nil, err
  end
  lock_fd = fd
  pcall(uv.fs_write, fd, instance_id .. "\n", 0)
  heartbeat_timer = uv.new_timer()
  heartbeat_timer:start(0, math.max(250, math.floor(config.broker_timeout_ms / 3)), function()
    touch_lock()
  end)
  return true
end

local function clear_stale_lock()
  local stat = uv.fs_stat(lock_path)
  if not stat or not stat.mtime then
    return false
  end
  local age_ms = (os.time() - stat.mtime.sec) * 1000
  if age_ms < config.broker_timeout_ms then
    return false
  end
  pcall(uv.fs_unlink, lock_path)
  if not is_windows() then
    pcall(uv.fs_unlink, socket_address)
  end
  return true
end

local function encode(payload)
  return vim.json.encode(payload) .. "\n"
end

local function write(handle, payload)
  if not handle or handle:is_closing() then
    return false
  end
  local ok, result, err = pcall(handle.write, handle, encode(payload))
  if not ok then
    state.error = tostring(result)
    return false
  elseif result == nil and err ~= nil then
    state.error = tostring(err)
    return false
  end
  return true
end

local function peer_count()
  local count = 0
  for peer in pairs(peers) do
    if peer.id then
      count = count + 1
    end
  end
  return count
end

local function broker_state_message()
  return {
    kind = "state",
    version = protocol_version,
    scope = config.scope,
    broker_id = instance_id,
    active_id = state.active_id,
    clients = peer_count(),
    midi = broker_midi_status,
  }
end

local function close_peer(peer)
  if not peers[peer] then
    return
  end
  peers[peer] = nil
  close_handle(peer.handle)
  if peer.id and state.active_id == peer.id then
    state.active_id = nil
  end
end

local function broadcast(payload)
  for peer in pairs(peers) do
    if peer.id and not write(peer.handle, payload) then
      close_peer(peer)
    end
  end
end

local function broadcast_state()
  state.clients = peer_count()
  broadcast(broker_state_message())
  emit_status()
end

local function find_peer(id)
  for peer in pairs(peers) do
    if peer.id == id then
      return peer
    end
  end
end

local function handle_peer_message(peer, message)
  if type(message) ~= "table" then
    return
  end

  if message.kind == "hello" then
    if message.version ~= protocol_version or message.scope ~= config.scope then
      write(peer.handle, {
        kind = "error",
        message = "incompatible Knobby coordination endpoint",
      })
      close_peer(peer)
      return
    end
    if type(message.instance_id) ~= "string" or message.instance_id == "" then
      close_peer(peer)
      return
    end
    local previous = find_peer(message.instance_id)
    if previous and previous ~= peer then
      close_peer(previous)
    end
    peer.id = message.instance_id
    peer.pid = message.pid
    write(peer.handle, broker_state_message())
    broadcast_state()
  elseif not peer.id then
    close_peer(peer)
  elseif message.kind == "activate" then
    state.active_id = peer.id
    broadcast_state()
  elseif message.kind == "deactivate" then
    -- A delayed FocusLost from the old client must not deactivate a newer one.
    if state.active_id == peer.id then
      state.active_id = nil
      broadcast_state()
    end
  elseif message.kind == "control" and type(message.action) == "string" then
    schedule_handler("on_control", message.action)
  end
end

local function read_messages(handle, receiver, on_close)
  local buffer = ""
  handle:read_start(function(err, data)
    if err or not data then
      on_close(err)
      return
    end
    buffer = buffer .. data
    if #buffer > 1024 * 1024 then
      on_close("coordination message exceeded buffer limit")
      return
    end
    while true do
      local newline = buffer:find("\n", 1, true)
      if not newline then
        break
      end
      local line = buffer:sub(1, newline - 1)
      buffer = buffer:sub(newline + 1)
      if line ~= "" then
        local ok, message = pcall(vim.json.decode, line)
        if ok then
          local received, receiver_error = pcall(receiver, message)
          if not received then
            state.error = tostring(receiver_error)
            emit_status()
          end
        end
      end
    end
  end)
end

local function accept_client(err)
  if err or not server or server:is_closing() then
    return
  end
  local handle = uv.new_pipe(false)
  local ok, accepted, accept_error = pcall(server.accept, server, handle)
  if not ok or (accepted == nil and accept_error ~= nil) then
    close_handle(handle)
    state.error = tostring(accept_error or accepted or "unable to accept coordination client")
    emit_status()
    return
  end
  local peer = { handle = handle }
  peers[peer] = true
  read_messages(handle, function(message)
    handle_peer_message(peer, message)
  end, function()
    local was_registered = peer.id ~= nil
    close_peer(peer)
    if was_registered then
      broadcast_state()
    end
  end)
end

local try_elect

local function schedule_retry(reason)
  close_retry_timer()
  if not state.desired then
    return
  end
  if reason and reason ~= "" then
    state.error = tostring(reason)
  end
  state.status = "electing"
  emit_status()
  retry_timer = uv.new_timer()
  local jitter = uv.os_getpid() % 71
  retry_timer:start(config.reconnect_interval_ms + jitter, 0, vim.schedule_wrap(function()
    close_retry_timer()
    try_elect()
  end))
end

local function handle_broker_message(message)
  if type(message) ~= "table" then
    return
  end
  if message.kind == "state" then
    if message.version ~= protocol_version or message.scope ~= config.scope then
      state.error = "incompatible Knobby coordination endpoint"
      emit_status()
      return
    end
    state.status = "connected"
    state.error = nil
    state.broker_id = message.broker_id
    state.active_id = message.active_id
    state.clients = message.clients or 0
    state.midi = message.midi
    if message.active_id and message.active_id ~= instance_id then
      wants_active = false
    end
    set_active(message.active_id == instance_id)
    emit_status()
  elseif message.kind == "midi_status" then
    state.midi = message.midi
    emit_status()
  elseif message.kind == "midi" and state.active and wants_active then
    local midi_message = vim.deepcopy(message.message)
    vim.schedule(function()
      if state.desired and state.active and wants_active and handlers.on_message then
        handlers.on_message(midi_message)
      end
    end)
  elseif message.kind == "error" then
    state.error = tostring(message.message or "coordination error")
    emit_status()
  end
end

local function send_client(payload)
  return write(client, payload)
end

local function connect_client()
  if not state.desired or client then
    return
  end
  local socket = uv.new_pipe(false)
  client = socket
  local client_generation = generation
  state.status = "connecting"
  emit_status()
  socket:connect(socket_address, function(err)
    if client_generation ~= generation or socket ~= client then
      close_handle(socket)
      return
    end
    if err then
      client = nil
      close_handle(socket)
      clear_stale_lock()
      schedule_retry(err)
      return
    end
    state.status = "connected"
    state.error = nil
    read_messages(socket, handle_broker_message, function(read_error)
      if socket ~= client then
        return
      end
      client = nil
      close_handle(socket)
      local was_active = state.active
      state.broker_id = nil
      state.active_id = nil
      state.clients = 0
      state.midi = nil
      set_active(false)
      if was_active then
        emit_status()
      end
      schedule_retry(read_error or "coordination broker disconnected")
    end)
    send_client({
      kind = "hello",
      version = protocol_version,
      scope = config.scope,
      instance_id = instance_id,
      pid = uv.os_getpid(),
    })
    if wants_active then
      send_client({ kind = "activate" })
    end
    emit_status()
  end)
end

local function close_server()
  local owned = server ~= nil or lock_fd ~= nil
  for peer in pairs(peers) do
    close_peer(peer)
  end
  peers = {}
  close_handle(server)
  server = nil
  broker_midi_status = nil
  if owned and not is_windows() and socket_address then
    pcall(uv.fs_unlink, socket_address)
  end
  release_lock()
end

try_elect = function()
  if not state.desired or client or server then
    return
  end
  close_retry_timer()
  state.status = "electing"
  state.endpoint = endpoint()
  emit_status()

  local locked, lock_error = acquire_lock()
  if locked then
    if not is_windows() then
      pcall(uv.fs_unlink, socket_address)
    end
    local candidate = uv.new_pipe(false)
    local bound, bind_error = candidate:bind(socket_address)
    if bound then
      local listening, listen_error = candidate:listen(32, accept_client)
      if listening then
        server = candidate
        state.broker_id = instance_id
        state.error = nil
        set_role("broker")
        connect_client()
        return
      end
      bind_error = listen_error
    end
    close_handle(candidate)
    release_lock()
    state.error = tostring(bind_error or "unable to listen on coordination endpoint")
  else
    state.error = nil
  end

  set_role("client")
  connect_client()
  if not client then
    schedule_retry(lock_error)
  end
end

function M.setup(opts, callbacks)
  M.stop()
  config = opts
  handlers = callbacks or {}
  instance_id = string.format("%d-%x", uv.os_getpid(), uv.hrtime())
  socket_address, lock_path = resolved_endpoints()
  wants_active = false
  state = {
    desired = false,
    status = "stopped",
    role = "none",
    active = false,
    active_id = nil,
    broker_id = nil,
    clients = 0,
    endpoint = endpoint(),
    error = nil,
    midi = nil,
  }
  emit_status()
end

function M.start()
  if not config then
    error("knobby: coordination is not configured")
  end
  if state.desired then
    return
  end
  state.desired = true
  state.status = "electing"
  try_elect()
end

function M.stop()
  generation = generation + 1
  local was_broker = state.role == "broker"
  local was_active = state.active
  state.desired = false
  wants_active = false
  close_retry_timer()
  close_handle(client)
  client = nil
  close_server()
  state.status = "stopped"
  state.broker_id = nil
  state.active_id = nil
  state.clients = 0
  state.midi = nil
  state.error = nil
  set_active(false)
  set_role("none")
  if was_active or was_broker then
    emit_status()
  end
end

function M.activate()
  wants_active = true
  if client and state.status == "connected" then
    return send_client({ kind = "activate" })
  end
  return false, "coordination broker is not connected"
end

function M.deactivate()
  wants_active = false
  if client and state.status == "connected" then
    return send_client({ kind = "deactivate" })
  end
  return false, "coordination broker is not connected"
end

function M.request(action)
  vim.validate({ action = { action, "string" } })
  if client and state.status == "connected" then
    return send_client({ kind = "control", action = action })
  end
  return false, "coordination broker is not connected"
end

function M.publish(message)
  if state.role ~= "broker" or not state.active_id then
    return false
  end
  local peer = find_peer(state.active_id)
  if not peer then
    state.active_id = nil
    broadcast_state()
    return false
  end
  return write(peer.handle, { kind = "midi", message = message })
end

function M.set_midi_status(midi_status)
  if state.role ~= "broker" then
    return
  end
  broker_midi_status = vim.deepcopy(midi_status)
  state.midi = vim.deepcopy(midi_status)
  broadcast({ kind = "midi_status", midi = broker_midi_status })
  emit_status()
end

function M.status()
  local result = vim.deepcopy(state)
  result.instance_id = instance_id
  result.wants_active = wants_active
  return result
end

return M
