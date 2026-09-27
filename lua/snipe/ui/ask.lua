local M = {}

local tasks = require("snipe.tasks")

local state = {
  win = nil,
  buf = nil,
  task = nil,
  consumed = 0,
}

local function append()
  local task = state.task
  if not task or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local output = task.output or ""
  local new_text = output:sub(state.consumed + 1)
  if new_text == "" then
    return
  end
  state.consumed = #output

  vim.bo[state.buf].modifiable = true
  local lines = vim.split(new_text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  if #lines > 0 then
    vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, lines)
  end

  if task.status == "done" or task.status == "error" then
    local footer = task.status == "done" and "— done —" or ("— error: " .. (task.error or "unknown") .. " —")
    vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { "", footer })
  end
  vim.bo[state.buf].modifiable = false

  for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(state.buf), 0 })
  end
end

local function close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  state.task = nil
  state.consumed = 0
end

local function open_result(task)
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.min(100, math.floor(vim.o.columns * 0.75))
  local height = math.min(30, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 3),
    style = "minimal",
    border = "rounded",
    title = " snipe — " .. task.name,
    title_pos = "center",
  })
  state.win = win
  state.buf = buf
  state.task = task
  state.consumed = 0
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<esc>", close, opts)

  append()
end

---Shorten a prompt for display.
local function short_name(prompt)
  local name = prompt:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #name > 40 then
    name = name:sub(1, 40) .. "…"
  end
  return name
end

---@param question string?
function M.ask(question)
  local function run(q)
    q = q:gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then
      return
    end
    local task = tasks.create({
      kind = "ask",
      name = "ask: " .. short_name(q),
      prompt = q,
      apply = "confirm",
    })
    open_result(task)
  end

  if question and question ~= "" then
    run(question)
  else
    vim.ui.input({ prompt = "snipe ask: " }, function(input)
      if input then
        run(input)
      end
    end)
  end
end

function M.setup()
  vim.api.nvim_create_autocmd("User", {
    pattern = "SnipeTaskUpdated",
    callback = function(e)
      if state.win and vim.api.nvim_win_is_valid(state.win) and state.task and e.data.id == state.task.id then
        vim.schedule(append)
      end
    end,
  })
end

return M
