local M = {}

---@class SnipeChatHandlers
---@field on_data fun(chunk: string, acc: string)?
---@field on_done fun(full: string)
---@field on_error fun(msg: string)

---Streaming chat against any OpenAI-compatible endpoint using curl + vim.uv.spawn.
---Never blocks the event loop.
---
---@param messages table[] {role, content}[]
---@param opts table {model?, temperature?, stream?}
---@param handlers SnipeChatHandlers
---@return table handle with a kill() method
function M.chat(messages, opts, handlers)
  opts = opts or {}
  local config = require("snipe.config")
  local prov = config.resolve_provider()

  local url = prov.base_url:gsub("/$", "") .. "/chat/completions"

  local body = {
    messages = messages,
    stream = opts.stream ~= false,
  }
  local model = opts.model or prov.model
  if model then
    body.model = model
  end
  local temperature = opts.temperature or config.options.temperature
  if temperature ~= nil then
    body.temperature = temperature
  end

  local args = {
    "curl",
    "-sS",
    "-N",
    "--fail",
    "--no-buffer",
    "--max-time",
    tostring(prov.timeout or 600),
    "-X",
    "POST",
    url,
    "-H",
    "Content-Type: application/json",
  }
  if prov.api_key and prov.api_key ~= "" then
    vim.list_extend(args, { "-H", "Authorization: Bearer " .. prov.api_key })
  end
  for _, header in ipairs(prov.headers or {}) do
    vim.list_extend(args, { "-H", header })
  end

  -- write the JSON body to a temp file to avoid stdin/quoting issues
  -- (use uv primitives: vim.fn.tempname() is forbidden in fast-event contexts)
  local tmp = vim.fs.joinpath(vim.uv.os_tmpdir(), "snipe-req-" .. tostring(vim.uv.hrtime()) .. ".json")
  local tmpf = io.open(tmp, "wb")
  if not tmpf then
    handlers.on_error("could not create request body file")
    return { kill = function() end }
  end
  tmpf:write(vim.json.encode(body))
  tmpf:close()
  vim.list_extend(args, { "--data-binary", "@" .. tmp })

  local stdout_pipe = vim.uv.new_pipe(false)
  local stderr_pipe = vim.uv.new_pipe(false)

  local acc = ""
  local buf = ""
  local resolved = false
  local handle = nil
  local stderr_chunks = {}

  local function cleanup()
    pcall(vim.uv.read_stop, stdout_pipe)
    pcall(vim.uv.read_stop, stderr_pipe)
    pcall(vim.uv.close, stdout_pipe)
    pcall(vim.uv.close, stderr_pipe)
    pcall(os.remove, tmp)
  end

  -- Resolve once, calling on_done.
  local function resolve_ok()
    if resolved then
      return
    end
    resolved = true
    if handle then
      pcall(vim.uv.process_kill, handle, 15) -- stop curl if it lingers
    end
    cleanup()
    if handlers.on_done then
      handlers.on_done(acc)
    end
  end

  -- Resolve once, calling on_error.
  local function resolve_error(msg)
    if resolved then
      return
    end
    resolved = true
    if handle then
      pcall(vim.uv.process_kill, handle, 15)
    end
    cleanup()
    if handlers.on_error then
      handlers.on_error(msg)
    end
  end

  local function on_read(err, data)
    if err then
      resolve_error("read error: " .. err)
      return
    end
    if not data then
      return -- EOF; the exit callback decides
    end
    buf = buf .. data
    while true do
      local nl = buf:find("\n")
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      line = line:gsub("\r$", "")
      if not line:match("^data:") then
        goto continue
      end
      local payload = line:sub(6)
      payload = payload:gsub("^%s+", ""):gsub("%s+$", "")
      if payload == "[DONE]" then
        resolve_ok()
        goto continue
      end
      local ok, decoded = pcall(vim.json.decode, payload)
      if ok and decoded then
        local choice = decoded.choices and decoded.choices[1]
        if choice then
          local content = choice.delta and choice.delta.content or (choice.message and choice.message.content)
          if content == vim.NIL then
            content = nil
          end
          if content and content ~= "" then
            acc = acc .. content
            if handlers.on_data then
              handlers.on_data(content, acc)
            end
          end
          if choice.finish_reason ~= nil and choice.finish_reason ~= vim.NIL then
            resolve_ok()
          end
        end
      end
      ::continue::
    end
  end

  handle = vim.uv.spawn("curl", {
    args = args,
    stdio = { nil, stdout_pipe, stderr_pipe },
  }, function(code, signal)
    if resolved then
      return
    end
    if signal and signal ~= 0 then
      resolve_error("cancelled")
      return
    end
    if code ~= 0 then
      resolve_error(("request failed (curl %d): %s"):format(code, table.concat(stderr_chunks, "")))
      return
    end
    resolve_ok()
  end)

  vim.uv.read_start(stdout_pipe, on_read)
  vim.uv.read_start(stderr_pipe, function(err, data)
    if data then
      table.insert(stderr_chunks, data)
    end
  end)

  return {
    kill = function()
      if handle then
        pcall(vim.uv.process_kill, handle, 15)
      end
    end,
  }
end

return M
