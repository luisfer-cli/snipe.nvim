local M = {}

---Parse the optional count suffix of a hunk header ("", ",3", "0", ",0").
---@param spec string
---@param default integer
local function hunk_count(spec, default)
  if spec == "" then
    return default
  end
  if spec:sub(1, 1) == "," then
    return tonumber(spec:sub(2)) or default
  end
  return tonumber(spec) or default
end

---Parse a single unified-diff hunk header line.
---@param line string
---@return integer? old_start, integer old_count, integer? new_start, integer new_count
local function parse_hunk_header(line)
  local before, after = line:match("^@@ %-(.-) %+(.-) @@$")
  if not before then
    return nil, 0, nil, 0
  end
  local ostart, orest = before:match("^(%d+)(.*)$")
  local nstart, nrest = after:match("^(%d+)(.*)$")
  if not ostart or not nstart then
    return nil, 0, nil, 0
  end
  return tonumber(ostart), hunk_count(orest, 1), tonumber(nstart), hunk_count(nrest, 1)
end

---Parse unified diff blocks from raw model output.
---@param text string
---@return table[] list of {file, hunks}
function M.parse_edits(text)
  local edits = {}
  local cur_file = nil
  local cur_hunk = nil

  local function close_hunk()
    if cur_file and cur_hunk then
      table.insert(cur_file.hunks, cur_hunk)
    end
    cur_hunk = nil
  end

  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", "")

    local new_file = line:match("^%+%+%+ b/(.+)$")
    if new_file then
      close_hunk()
      cur_file = { file = new_file, hunks = {} }
      table.insert(edits, cur_file)
    elseif line:match("^@@") and cur_file then
      close_hunk()
      local ostart, ocount, nstart, ncount = parse_hunk_header(line)
      if ostart then
        cur_hunk = {
          old_start = ostart,
          old_count = ocount,
          new_start = nstart,
          new_count = ncount,
          lines = {},
        }
      end
    elseif cur_hunk then
      local c = line:sub(1, 1)
      if c == "+" then
        table.insert(cur_hunk.lines, { t = "add", text = line:sub(2) })
      elseif c == "-" then
        table.insert(cur_hunk.lines, { t = "del", text = line:sub(2) })
      elseif c == " " then
        table.insert(cur_hunk.lines, { t = "ctx", text = line:sub(2) })
      elseif c == "\\" then
        -- "\ No newline at end of file": ignore
      else
        close_hunk()
      end
    end
  end
  close_hunk()

  return edits
end

---Apply hunks against an array of lines.
---@param lines string[]
---@param hunks table[]
---@return string[]? new_lines, string? err
local function apply_hunks(lines, hunks)
  local cur = vim.deepcopy(lines)
  local delta = 0

  for _, h in ipairs(hunks) do
    local idx = h.old_start - 1 + delta
    if idx < 0 then
      idx = 0
    end

    -- verify context / deleted lines against current file
    local offset = 0
    for _, op in ipairs(h.lines) do
      if op.t == "del" or op.t == "ctx" then
        local current = cur[idx + offset + 1]
        if current == nil or current ~= op.text then
          return nil,
            ("context mismatch at line %d (expected %q, got %q)"):format(idx + offset + 1, op.text, tostring(current))
        end
        offset = offset + 1
      end
    end

    local new_lines = {}
    for _, op in ipairs(h.lines) do
      if op.t == "add" or op.t == "ctx" then
        table.insert(new_lines, op.text)
      end
    end

    for _ = 1, h.old_count do
      table.remove(cur, idx + 1)
    end
    for i = #new_lines, 1, -1 do
      table.insert(cur, idx + 1, new_lines[i])
    end

    delta = delta + h.new_count - h.old_count
  end

  return cur, nil
end

---Write lines back to a file (with trailing newline).
---@param abs string
---@param lines string[]
local function write_file(abs, lines)
  local f = io.open(abs, "wb")
  if not f then
    return false
  end
  f:write(table.concat(lines, "\n"))
  if #lines > 0 then
    f:write("\n")
  end
  f:close()
  return true
end

---Apply parsed edits to buffers/files. Requires the task context (root).
---@param edits table[]
---@param task table (has ctx.root)
---@return table[] results {file, applied?, error?, orig?, new?}
function M.apply_edits(edits, task)
  local context = require("snipe.context")
  local root = task.ctx and task.ctx.root or vim.uv.cwd()
  local results = {}

  for _, ed in ipairs(edits) do
    local rel = ed.file
    if rel:match("^%.%.%/") or rel:match("^/") or rel:match(":") then
      table.insert(results, { file = rel, error = "unsafe path skipped" })
      goto continue
    end
    local abs = vim.fn.resolve(vim.fs.joinpath(root, rel))

    local buf = vim.fn.bufnr(abs)
    local lines
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
      if vim.api.nvim_buf_get_option(buf, "mod") then
        table.insert(results, { file = rel, error = "buffer has unsaved changes" })
        goto continue
      end
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    else
      buf = -1
      lines = context.read_file_lines(abs)
      if not lines then
        table.insert(results, { file = rel, error = "file not found or binary" })
        goto continue
      end
    end

    local new_lines, err = apply_hunks(lines, ed.hunks)
    if not new_lines then
      table.insert(results, { file = rel, error = err })
      goto continue
    end

    local ok = true
    if buf ~= -1 then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
      vim.bo[buf].modified = true
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("write")
      end)
      if vim.api.nvim_buf_get_option(buf, "mod") then
        ok = false
      end
    else
      ok = write_file(abs, new_lines)
    end

    if not ok then
      table.insert(results, { file = rel, error = "failed to write file" })
    else
      table.insert(results, { file = rel, applied = true, orig = lines, new = new_lines, abs = abs, buf = buf })
    end
    ::continue::
  end

  return results
end

---Revert a previously applied set of edits.
---@param results table[]
---@return integer reverted
function M.revert_results(results)
  local context = require("snipe.context")
  local reverted = 0
  for _, r in ipairs(results) do
    if r.applied then
      if r.buf ~= -1 and vim.api.nvim_buf_is_valid(r.buf) then
        vim.api.nvim_buf_set_lines(r.buf, 0, -1, false, r.orig)
        vim.bo[r.buf].modified = true
        vim.api.nvim_buf_call(r.buf, function()
          vim.cmd("write")
        end)
      elseif r.abs then
        local f = io.open(r.abs, "wb")
        if f then
          f:write(table.concat(r.orig, "\n"))
          if #r.orig > 0 then
            f:write("\n")
          end
          f:close()
        end
      end
      reverted = reverted + 1
    end
  end
  return reverted
end

return M
