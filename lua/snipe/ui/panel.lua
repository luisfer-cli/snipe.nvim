local M = {}

local tasks = require("snipe.tasks")

local state = {
  win = nil,
  buf = nil,
  sel = 1,
  rows = {}, -- line -> task id
  ns = vim.api.nvim_create_namespace("snipe.panel"),
  visible = false,
}

local ICONS = {
  queued = "○",
  running = "⚡",
  review = "✋",
  done = "✓",
  error = "✗",
  killed = "✕",
  reverted = "↺",
}

local function esc(s)
  s = s:gsub("%\n", " ")
  if #s > 60 then
    s = s:sub(1, 60) .. "…"
  end
  return s
end

local function render()
  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

  local list = tasks.list()
  local lines = {}
  state.rows = {}

  table.insert(lines, " snipe — tasks  (j/k move · <cr> apply · o log · x kill · d dismiss · q close) ")
  table.insert(lines, "")

  if #list == 0 then
    table.insert(lines, "  No tasks yet.  :SnipeTask <prompt>   or   :SnipeAsk <question>")
  end

  for _, t in ipairs(list) do
    local icon = ICONS[t.status] or "?"
    local age = os.time() - (t.created or os.time())
    local mins = math.floor(age / 60)
    local ago = mins > 0 and ("%dm"):format(mins) or ("%ds"):format(age)
    local line = (" %s %-8s %s  %s  [%s]"):format(icon, t.status, esc(t.name), esc(t.status_msg), ago)
    table.insert(lines, line)
    state.rows[#lines] = t.id
  end

  table.insert(lines, "")
  if #list > 0 then
    table.insert(lines, " <cr> apply pending edits · o open log · x kill · d dismiss")
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- highlight selected row
  vim.api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
  local sel_line = state.rows[state.sel]
  if sel_line then
    vim.api.nvim_buf_set_extmark(buf, state.ns, sel_line, 0, {
      hl_group = "SnipePanelSelected",
      end_line = sel_line + 1,
      priority = 100,
    })
  end

  local row = math.min(state.sel + 1, #lines)
  pcall(vim.api.nvim_win_set_cursor, state.win, { row, 0 })
end

local function selected_task()
  local id = state.rows[state.sel]
  if not id then
    return nil
  end
  return tasks.get(id)
end

local function move(delta)
  local n = #state.rows
  if n == 0 then
    return
  end
  state.sel = ((state.sel - 1 + delta + n) % n) + 1
  render()
end

local function apply_selected()
  local t = selected_task()
  if not t then
    return
  end
  if t.status == "review" then
    tasks.apply(t.id)
  elseif t.status == "running" then
    vim.notify(("task %s is still running"):format(t.id), vim.log.levels.INFO, { title = "snipe" })
  end
end

local function open_selected_log()
  local t = selected_task()
  if t then
    M.close()
    vim.schedule(function()
      tasks.open_log(t.id)
    end)
  end
end

local function kill_selected()
  local t = selected_task()
  if t and t.status == "running" then
    tasks.kill(t.id)
  end
end

local function dismiss_selected()
  local t = selected_task()
  if t then
    tasks.dismiss(t.id)
    state.sel = math.min(state.sel, #state.rows)
    render()
  end
end

function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.min(92, math.floor(vim.o.columns * 0.75))
  local height = math.min(18, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " snipe ",
    title_pos = "center",
  })
  state.win = win
  state.buf = buf
  state.sel = 1
  state.visible = true
  vim.bo[buf].bufhidden = "wipe"

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "j", function()
    move(1)
  end, opts)
  vim.keymap.set("n", "k", function()
    move(-1)
  end, opts)
  vim.keymap.set("n", "<down>", function()
    move(1)
  end, opts)
  vim.keymap.set("n", "<up>", function()
    move(-1)
  end, opts)
  vim.keymap.set("n", "<cr>", apply_selected, opts)
  vim.keymap.set("n", "o", open_selected_log, opts)
  vim.keymap.set("n", "x", kill_selected, opts)
  vim.keymap.set("n", "d", dismiss_selected, opts)
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<esc>", M.close, opts)
  vim.keymap.set("t", "<esc>", M.close, opts)

  render()
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  state.visible = false
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

function M.is_open()
  return state.visible
end

function M.setup()
  vim.api.nvim_create_autocmd("User", {
    pattern = "SnipeTaskUpdated",
    callback = function()
      if state.visible and state.win and vim.api.nvim_win_is_valid(state.win) then
        vim.schedule(render)
      end
    end,
  })
end

return M
