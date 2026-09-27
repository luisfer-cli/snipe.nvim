local M = {}

local ROOT_MARKERS = {
  ".git",
  "package.json",
  "Cargo.toml",
  "pyproject.toml",
  "go.mod",
  "tsconfig.json",
  "Makefile",
  "flake.nix",
  "pom.xml",
  "composer.json",
}

---@param path string
local function split_lines(data)
  local lines = {}
  for line in data:gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  if not data:match("\n$") and data ~= "" then
    table.insert(lines, data:match("([^\n]*)$"))
  end
  return lines
end

---@param bufnr integer
function M.find_root(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr or 0)
  if file and file ~= "" then
    local root = vim.fs.root(file, ROOT_MARKERS)
    if root then
      return root
    end
  end
  return vim.uv.cwd()
end

---@param bufnr integer
---@return string[] lines of the buffer
function M.buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false)
end

---Read a file as lines, guarding against binary / very large files.
---@param abs string absolute path
---@param max_chars integer?
---@return string[]? lines
function M.read_file_lines(abs, max_chars)
  local stat = vim.uv.fs_stat(abs)
  if not stat then
    return nil
  end
  if stat.size > (max_chars or 1e6) * 2 then
    return nil
  end
  local f = io.open(abs, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  if data:find("\0", 1, true) then
    return nil -- binary
  end
  return split_lines(data)
end

---Summarize the diagnostics of a buffer (for the prompt).
---@param bufnr integer
---@return string
local function diagnostics_summary(bufnr)
  local config = require("snipe.config")
  if not config.options.context.include_diagnostics then
    return ""
  end
  local diags = vim.diagnostic.get(bufnr or 0)
  if #diags == 0 then
    return "No diagnostics."
  end
  local counts = { [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
  for _, d in ipairs(diags) do
    counts[d.severity or 3] = (counts[d.severity or 3] or 0) + 1
  end
  local names = { "ERROR", "WARN", "INFO", "HINT" }
  local parts = {}
  for sev = 1, 4 do
    if counts[sev] and counts[sev] > 0 then
      table.insert(parts, ("%s=%d"):format(names[sev], counts[sev]))
    end
  end
  local samples = {}
  local seen = 0
  for _, d in ipairs(diags) do
    if d.severity and d.severity <= 2 and seen < 5 then
      table.insert(samples, ("L%d: %s"):format(d.lnum + 1, d.message))
      seen = seen + 1
    end
  end
  local text = ("Diagnostics (%s):"):format(table.concat(parts, ", "))
  for _, s in ipairs(samples) do
    text = text .. "\n  " .. s
  end
  return text
end

---Find the name of the function/symbol containing the cursor via LSP.
---@param bufnr integer
---@param cursor_line integer 0-based line
---@param cb fun(name: string?)
local function current_symbol(bufnr, cursor_line, cb)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local settled = false
  local timer = vim.uv.new_timer()

  local function settle(name)
    if not settled then
      settled = true
      timer:stop()
      timer:close()
      cb(name)
    end
  end

  timer:start(2000, 0, function()
    settle(nil)
  end)
  timer:unref()

  local requested = false
  for _, client in ipairs(clients) do
    if client.supports_method("textDocument/documentSymbol", bufnr) then
      requested = true
      local params = vim.lsp.util.make_position_params(0, "utf-8")
      vim.lsp.buf_request(bufnr, "textDocument/documentSymbol", params, function(err, result)
        if err or not result then
          return
        end
        local symbols = vim.lsp.util.symbols_to_flat_table(result)
        local best = nil
        for _, s in ipairs(symbols) do
          if s.range and s.range.start.line <= cursor_line and s.range["end"].line >= cursor_line then
            if
              not best
              or (s.range["end"].line - s.range.start.line) < (best.range["end"].line - best.range.start.line)
            then
              best = s
            end
          end
        end
        settle(best and best.name or nil)
      end)
      break
    end
  end
  if not requested then
    settle(nil)
  end
end

---Project files list: git ls-files limited + recently used buffers.
---@param root string
---@param cb fun(files: string[])
local function project_files(root, cb)
  local config = require("snipe.config")
  local files = {}

  local buffers = {}
  for _, b in ipairs(vim.fn.getbufinfo({ buflisted = true })) do
    if b.name and b.name ~= "" and vim.fn.filereadable(b.name) == 1 then
      table.insert(buffers, { name = b.name, lastused = b.lastused })
    end
  end
  table.sort(buffers, function(a, b2)
    return a.lastused > b2.lastused
  end)

  vim.system({ "git", "ls-files" }, { cwd = root, text = true }, function(res)
    if res.code == 0 then
      for line in res.stdout:gmatch("[^\r\n]+") do
        if not line:match("^%.git/") then
          files[line] = true
        end
      end
    end
    -- recent buffers first
    local ordered = {}
    local seen = {}
    for _, b in ipairs(buffers) do
      local rel = vim.fs.relpath(root, b.name)
      if rel and not rel:match("^%.%.%/") and not seen[rel] then
        seen[rel] = true
        table.insert(ordered, rel)
      end
    end
    for name in pairs(files) do
      if not seen[name] then
        seen[name] = true
        table.insert(ordered, name)
      end
    end
    cb(ordered)
  end)
end

---Git status (modified/untracked files) for the prompt.
---@param root string
---@param cb fun(files: string[])
local function git_status(root, cb)
  local config = require("snipe.config")
  if not config.options.context.include_git_status then
    cb({})
    return
  end
  vim.system({ "git", "status", "--porcelain", "--short" }, { cwd = root, text = true }, function(res)
    if res.code ~= 0 then
      cb({})
      return
    end
    local files = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
      local path = line:match("^%S+%s+(.+)$")
      if path then
        table.insert(files, path)
      end
    end
    cb(files)
  end)
end

---Truncate text with a marker.
---@param text string
---@param max integer
local function truncate(text, max)
  if #text <= max then
    return text
  end
  return text:sub(1, max) .. "\n... [truncated " .. (#text - max) .. " chars]"
end

---Gather project context and build the full user message.
---@param task table
---@param cb fun(context: string)
function M.gather(task, cb)
  local config = require("snipe.config")
  local bufnr = task.bufnr or 0
  local root = M.find_root(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

  local current_file = vim.api.nvim_buf_get_name(bufnr)
  local current_rel = current_file ~= "" and vim.fs.relpath(root, current_file) or nil
  local current_ft = vim.bo[bufnr].filetype or ""

  local sync_parts = {}
  table.insert(sync_parts, ("Project root: %s"):format(root))
  if current_rel then
    table.insert(sync_parts, ("Current file: %s (%s)"):format(current_rel, current_ft))
  end
  table.insert(sync_parts, diagnostics_summary(bufnr))

  local ctx_max = config.options.context.max_context_chars

  -- current buffer content (always included, top budget)
  local buffer_text = ""
  if current_rel then
    local lines = M.buffer_lines(bufnr)
    buffer_text = table.concat(lines, "\n")
    local max_chars = config.options.context.max_file_chars
    buffer_text = truncate(buffer_text, max_chars)
  end

  local pending = 3
  local modified = {}
  local project = {}
  local symbol = nil

  local function step()
    pending = pending - 1
    if pending > 0 then
      return
    end
    M._compose(
      {
        root = root,
        current_rel = current_rel,
        current_ft = current_ft,
        symbol = symbol,
        sync = sync_parts,
        modified = modified,
        project = project,
        buffer_text = buffer_text,
        max_context_chars = ctx_max,
      },
      task,
      function(text)
        cb({ root = root, text = text })
      end
    )
  end

  git_status(root, function(files)
    modified = files
    step()
  end)

  project_files(root, function(files)
    project = files
    step()
  end)

  if current_rel then
    current_symbol(bufnr, cursor_line, function(name)
      symbol = name
      step()
    end)
  else
    step()
  end
end

---Compose the final context text, reading contents of the most relevant files.
---@param data table
---@param task table
---@param cb fun(context: string)
function M._compose(data, task, cb)
  local config = require("snipe.config")
  local ctx_opts = config.options.context
  local lines = {}
  vim.list_extend(lines, data.sync)
  table.insert(lines, "")

  if data.symbol then
    table.insert(lines, ("Current symbol: %s"):format(data.symbol))
  end

  if #data.modified > 0 then
    table.insert(lines, "")
    table.insert(lines, "Modified files (git status):")
    for _, f in ipairs(data.modified) do
      table.insert(lines, "- " .. f)
    end
  end

  -- Pick extra files by content: current rel excluded, prefer modified files.
  local wanted = {}
  local seen = {}
  if data.current_rel then
    seen[data.current_rel] = true
  end
  local function add(f)
    if #wanted >= ctx_opts.max_files then
      return
    end
    if not seen[f] and not f:match("^%.git/") then
      seen[f] = true
      table.insert(wanted, f)
    end
  end
  for _, f in ipairs(data.modified) do
    add(f)
  end
  for _, f in ipairs(data.project) do
    add(f)
  end

  local budget = data.max_context_chars
  local used = #table.concat(lines, "\n") + #(data.buffer_text or "")

  local contents = {}
  if data.current_rel then
    table.insert(contents, {
      rel = data.current_rel,
      ft = data.current_ft,
      text = data.buffer_text or "",
    })
  end

  for _, rel in ipairs(wanted) do
    if used >= budget then
      break
    end
    local abs = vim.fs.joinpath(data.root, rel)
    local stat = vim.uv.fs_stat(abs)
    if stat and stat.size <= ctx_opts.max_file_chars * 2 then
      local flines = M.read_file_lines(abs)
      if flines then
        local text = table.concat(flines, "\n")
        text = truncate(text, ctx_opts.max_file_chars)
        local ft = vim.filetype.match({ filename = rel }) or ""
        table.insert(contents, { rel = rel, ft = ft, text = text })
        used = used + #text
      end
    end
  end

  table.insert(lines, "")
  if #contents == 0 then
    table.insert(lines, "(no file contents available)")
  else
    table.insert(lines, "FILE CONTENTS:")
    for _, c in ipairs(contents) do
      table.insert(lines, "")
      table.insert(lines, ("=== %s ==="):format(c.rel))
      table.insert(lines, ("```%s"):format(c.ft))
      table.insert(lines, c.text)
      table.insert(lines, "```")
    end
  end

  cb(table.concat(lines, "\n"))
end

M.split_lines = split_lines

return M
