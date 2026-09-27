local M = {}

-- Keys are stored in ~/.config/snipe/key with 0600 permissions, one per
-- provider: <provider>=<key>. Prefer the provider-specific environment
-- variable; this is the last-resort fallback (and what :SnipeAuth writes).

local function key_file()
  return vim.fs.normalize("~/.config/snipe/key")
end

local function ensure_dir()
  vim.fn.mkdir(vim.fn.fnamemodify(key_file(), ":h"), "p")
end

---Extract a clean key from possibly-mangled paste input (markdown tables,
---spaces, trailing junk, stray "provider=key" fragments).
---@param input string
---@return string
function M.sanitize(input)
  if not input then
    return ""
  end
  input = input:gsub("\r", " "):gsub("\n", " "):gsub("\t", " ")
  local candidate = input
  local after_eq = input:match("=[^=]*$")
  if after_eq then
    candidate = after_eq:sub(2)
  end
  candidate = candidate:gsub("^[%s|]+", ""):gsub("[%s|]+$", "")
  local token = candidate:match("([%S]+)%s*$") or candidate
  token = token:gsub("%s+", "")
  return token
end

---Read the stored key for a provider.
---@param provider string
---@return string?
function M.get(provider)
  local file = key_file()
  if not vim.uv.fs_stat(file) then
    return nil
  end
  local f = io.open(file, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  for line in data:gmatch("[^\r\n]+") do
    local p, k = line:match("^([^=]+)=(.*)$")
    if p and k and p == provider then
      return k
    end
  end
  return nil
end

---Store the key for a provider, preserving other providers.
---@param provider string
---@param key string
---@return boolean
function M.set(provider, key)
  key = M.sanitize(key)
  if key == "" then
    return false
  end
  ensure_dir()
  local file = key_file()
  local lines = {}
  local found = false

  if vim.uv.fs_stat(file) then
    local f = io.open(file, "rb")
    if f then
      for line in f:read("*a"):gmatch("[^\r\n]+") do
        local p = line:match("^([^=]+)=")
        if p and p == provider then
          lines[#lines + 1] = provider .. "=" .. key
          found = true
        elseif p and p:match("^[%w%-_]+$") then
          -- keep valid providers (drops mangled lines like "order md table=...")
          lines[#lines + 1] = line
        end
      end
      f:close()
    end
  end
  if not found then
    lines[#lines + 1] = provider .. "=" .. key
  end

  local f = io.open(file, "wb")
  if not f then
    return false
  end
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
  vim.uv.fs_chmod(file, 384) -- 0o600
  return true
end

---Remove the stored key for a provider.
---@param provider string
---@return boolean removed
function M.remove(provider)
  local file = key_file()
  if not vim.uv.fs_stat(file) then
    return false
  end
  local f = io.open(file, "rb")
  if not f then
    return false
  end
  local lines = {}
  local removed = false
  for line in f:read("*a"):gmatch("[^\r\n]+") do
    local p = line:match("^([^=]+)=")
    if p and p == provider then
      removed = true
    else
      lines[#lines + 1] = line
    end
  end
  f:close()

  if #lines == 0 then
    os.remove(file)
  else
    local w = io.open(file, "wb")
    if w then
      w:write(table.concat(lines, "\n") .. "\n")
      w:close()
    end
  end
  return removed
end

---Interactive command: :SnipeAuth [provider]
---@param provider string?
function M.command(provider)
  local config = require("snipe.config")
  if not provider or provider == "" then
    provider = config.resolve_provider().name
  end
  provider = provider:gsub("^%s+", ""):gsub("%s+$", "")
  if provider == "" then
    vim.notify("snipe: could not determine provider", vim.log.levels.WARN, { title = "snipe" })
    return
  end

  local existing = M.get(provider)
  local prompt = ("snipe auth — API key for %s: "):format(provider)
  if existing then
    prompt = ("snipe auth — API key for %s (leave empty to keep stored key): "):format(provider)
  end

  vim.ui.input({ prompt = prompt }, function(input)
    if input == nil then
      return
    end
    local key = M.sanitize(input)
    if key == "" then
      if existing then
        vim.notify(("snipe: key for %s unchanged"):format(provider), vim.log.levels.INFO, { title = "snipe" })
      else
        vim.notify("snipe: no key provided", vim.log.levels.INFO, { title = "snipe" })
      end
      return
    end
    if M.set(provider, key) then
      vim.notify(
        ("snipe: API key saved for %s (~/.config/snipe/key)"):format(provider),
        vim.log.levels.INFO,
        { title = "snipe" }
      )
    else
      vim.notify("snipe: failed to save API key", vim.log.levels.ERROR, { title = "snipe" })
    end
  end)
end

---:SnipeAuthRemove [provider]
---@param provider string?
function M.command_remove(provider)
  local config = require("snipe.config")
  if not provider or provider == "" then
    provider = config.resolve_provider().name
  end
  provider = provider:gsub("^%s+", ""):gsub("%s+$", "")
  if M.remove(provider) then
    vim.notify(("snipe: key removed for %s"):format(provider), vim.log.levels.INFO, { title = "snipe" })
  else
    vim.notify(("snipe: no stored key for %s"):format(provider), vim.log.levels.INFO, { title = "snipe" })
  end
end

return M
