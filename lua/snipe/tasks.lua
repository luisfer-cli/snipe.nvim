local M = {}

local config = require("snipe.config")
local provider = require("snipe.provider")
local context = require("snipe.context")
local prompts = require("snipe.prompts")
local diff = require("snipe.diff")

M.tasks = {}
local queue = {}
local running = 0
local id_counter = 0

-- forward declarations (mutual recursion)
local finalize
local dispatch
local next_round

---Emit a User autocmd so UI (panel, statusline) can refresh.
---@param task table
local function emit(task)
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", {
      pattern = "SnipeTaskUpdated",
      data = { id = task.id },
      modeline = false,
    })
  end)
end

local function notify(msg, level)
  if config.options.notify then
    vim.notify(msg, level or vim.log.levels.INFO, { title = "snipe" })
  end
end

---@param task table
local function ensure_logbuf(task)
  if not task.logbuf or not vim.api.nvim_buf_is_valid(task.logbuf) then
    local buf = vim.api.nvim_create_buf(false, true)
    task.logbuf = buf
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].modifiable = false
  end
  return task.logbuf
end

---@param task table
---@param text string
local function append_log(task, text)
  if not text or text == "" then
    return
  end
  local buf = ensure_logbuf(task)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  if #lines == 0 then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

---Update task.status_msg from the last complete <status> block in the output.
---@param task table
---@param acc string
local function parse_status(task, acc)
  local last = nil
  for s in acc:gmatch("<status>(.-)</status>") do
    last = s
  end
  if last and last ~= "" then
    task.status_msg = last:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end
end

---Collect <read file="..."> requests from model output.
---@param text string
---@return string[]
local function collect_reads(text)
  local reads = {}
  for path in text:gmatch('<read file="([^"]-)"') do
    table.insert(reads, path)
  end
  for path in text:gmatch("<read file='([^']-)'") do
    table.insert(reads, path)
  end
  return reads
end

---Files requested but not yet served to the model.
---@param task table
local function unserved_reads(task)
  local out = {}
  for f in pairs(task.reads) do
    if not task.reads_served[f] then
      table.insert(out, f)
    end
  end
  return out
end

local function set_status(task, status, msg)
  task.status = status
  task.status_msg = msg
  emit(task)
end

---@param task table
finalize = function(task)
  running = math.max(0, running - 1)

  local edits = diff.parse_edits(task.output, task.ctx.root)
  task.edits = edits
  task.finished = os.time()

  if #edits == 0 then
    task.status = "done"
    task.status_msg = "no code changes"
    notify(("%s: %s"):format(task.name, "done, no code changes"))
    emit(task)
    dispatch()
    return
  end

  if task.apply == "auto" then
    task.status = "running"
    task.status_msg = "applying edits"
    emit(task)
    local results = diff.apply_edits(edits, task)
    task.apply_results = results
    local ok_count, err_count = 0, 0
    for _, r in ipairs(results) do
      if r.applied then
        ok_count = ok_count + 1
      else
        err_count = err_count + 1
        notify(("apply error in %s: %s"):format(r.file, r.error), vim.log.levels.WARN)
      end
    end
    task.status = err_count > 0 and "error" or "done"
    task.status_msg = ("applied %d/%d edit(s)"):format(ok_count, #results)
    if ok_count > 0 then
      task.after_apply(results)
    end
    notify(("%s: %s"):format(task.name, task.status_msg))
    emit(task)
    dispatch()
  else
    task.status = "review"
    task.status_msg = ("%d edit(s) ready to apply"):format(#edits)
    notify(("%s: %d edit(s) ready to apply (review)"):format(task.name, #edits))
    emit(task)
    dispatch()
  end
end

---Run the next queued task when capacity allows.
dispatch = function()
  local max = config.options.tasks.max_parallel
  while running < max and #queue > 0 do
    local task = table.remove(queue, 1)
    running = running + 1
    set_status(task, "running", "working")
    next_round(task)
  end
end

---@param task table
next_round = function(task)
  if task.status == "killed" then
    return
  end
  local conversation = task.conversation
  if not conversation then
    conversation = {
      { role = "system", content = prompts.system(task.kind) },
      { role = "user", content = prompts.user_message(task) },
    }
    task.conversation = conversation
  end

  task.rounds = (task.rounds or 0) + 1
  if task.rounds > config.options.tasks.max_rounds then
    set_status(task, "running", "reached max rounds, finalizing")
    finalize(task)
    return
  end

  set_status(task, "running", task.rounds == 1 and "working" or ("round %d"):format(task.rounds))

  -- provider.chat must run in the main loop: it is often reached from a
  -- vim.system/uv callback (fast event) where vimscript helpers are forbidden.
  local handlers = {
    on_data = function(chunk, acc)
      vim.schedule(function()
        if task.status == "killed" or task.status == "error" then
          return
        end
        task.output = task.output .. chunk
        append_log(task, chunk)
        parse_status(task, acc)
        emit(task)
      end)
    end,
    on_done = function(full)
      vim.schedule(function()
        if task.status == "killed" then
          return
        end
        append_log(task, "\n")
        task.output = task.output .. "\n"
        table.insert(conversation, { role = "assistant", content = full })

        for _, f in ipairs(collect_reads(full)) do
          task.reads[f] = true
        end
        local unserved = unserved_reads(task)
        if #unserved > 0 and #unserved <= config.options.tasks.max_reads then
          set_status(task, "running", ("reading %d file(s)"):format(#unserved))
          local message = prompts.read_message(task, unserved)
          for _, f in ipairs(unserved) do
            task.reads_served[f] = true
          end
          table.insert(conversation, { role = "user", content = message })
          vim.schedule(function()
            next_round(task)
          end)
        else
          finalize(task)
        end
      end)
    end,
    on_error = function(msg)
      vim.schedule(function()
        if task.status == "killed" then
          return
        end
        task.error = msg
        task.finished = os.time()
        running = math.max(0, running - 1)
        set_status(task, "error", msg)
        append_log(task, ("\n[error] %s"):format(msg))
        notify(msg, vim.log.levels.ERROR)
        if msg:match("401") or msg:match("403") then
          notify(
            ("Auth error on %s — run :SnipeAuth %s to set the API key"):format(
              task.kind,
              config.resolve_provider().name
            ),
            vim.log.levels.ERROR
          )
        end
        dispatch()
      end)
    end,
  }
  task.job = nil
  vim.schedule(function()
    if task.status == "killed" then
      return
    end
    task.job = provider.chat(conversation, { model = config.model_for(task.kind) }, handlers)
  end)
end

---Create a new task and start gathering context.
---@param opts table {kind, name, prompt, apply, bufnr}
---@return table task
function M.create(opts)
  id_counter = id_counter + 1
  local task = {
    id = ("t%d"):format(id_counter),
    kind = opts.kind or "task",
    name = opts.name or "task",
    prompt = opts.prompt or "",
    apply = opts.apply or config.options.tasks.apply or "confirm",
    bufnr = opts.bufnr,
    status = "queued",
    status_msg = "gathering context",
    output = "",
    logbuf = nil,
    edits = {},
    apply_results = {},
    reads = {},
    reads_served = {},
    rounds = 0,
    created = os.time(),
    after_apply = opts.after_apply or M.after_apply,
  }
  table.insert(M.tasks, task)
  emit(task)

  context.gather(task, function(ctx)
    if task.status == "killed" then
      return
    end
    task.ctx = ctx
    set_status(task, "queued", "queued")
    table.insert(queue, task)
    dispatch()
  end)

  return task
end

---Kill a running task. With no argument, kills the last running task.
---@param id string?
function M.kill(id)
  local target = nil
  if id then
    target = M.get(id)
  else
    for i = #M.tasks, 1, -1 do
      if M.tasks[i].status == "running" then
        target = M.tasks[i]
        break
      end
    end
  end
  if not target then
    return nil
  end
  if target.status == "queued" then
    for i, t in ipairs(queue) do
      if t == target then
        table.remove(queue, i)
        break
      end
    end
    target.status = "killed"
    target.status_msg = "killed"
    emit(target)
    return target
  end
  if target.status == "running" then
    target.status = "killed"
    target.status_msg = "killed"
    emit(target)
    if target.job then
      target.job.kill()
    end
    running = math.max(0, running - 1)
    dispatch()
    return target
  end
  return nil
end

---Apply pending edits of a task in "review" state.
---@param id string
---@return table[]? results
function M.apply(id)
  local task = M.get(id)
  if not task or task.status ~= "review" then
    return nil
  end
  task.status = "running"
  task.status_msg = "applying edits"
  emit(task)
  local results = diff.apply_edits(task.edits, task)
  task.apply_results = results
  local ok_count, err_count = 0, 0
  for _, r in ipairs(results) do
    if r.applied then
      ok_count = ok_count + 1
    else
      err_count = err_count + 1
      notify(("apply error in %s: %s"):format(r.file, r.error), vim.log.levels.WARN)
    end
  end
  task.status = err_count > 0 and "error" or "done"
  task.status_msg = ("applied %d/%d edit(s)"):format(ok_count, #results)
  task.finished = os.time()
  if ok_count > 0 then
    task.after_apply(results)
  end
  emit(task)
  return results
end

---Revert applied edits of a task.
---@param id string
function M.revert(id)
  local task = M.get(id)
  if not task then
    return nil
  end
  local n = diff.revert_results(task.apply_results)
  task.apply_results = {}
  task.status = "reverted"
  task.status_msg = ("reverted %d edit(s)"):format(n)
  emit(task)
  return n
end

---Dismiss (remove) a finished task.
---@param id string
function M.dismiss(id)
  for i, t in ipairs(M.tasks) do
    if t.id == id then
      if t.logbuf and vim.api.nvim_buf_is_valid(t.logbuf) then
        vim.api.nvim_buf_delete(t.logbuf, { force = true })
      end
      table.remove(M.tasks, i)
      emit(t)
      return true
    end
  end
  return false
end

---@param id string
---@return table?
function M.get(id)
  for _, t in ipairs(M.tasks) do
    if t.id == id then
      return t
    end
  end
  return nil
end

function M.list()
  return M.tasks
end

---Open the log buffer of a task in a split.
---@param id string
function M.open_log(id)
  local task = M.get(id)
  if not task then
    return
  end
  ensure_logbuf(task)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, task.logbuf)
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(task.logbuf), 0 })
end

---Run LSP formatting on the buffers touched by an apply, then save.
---@param results table[]
function M.format_results(results)
  if not config.options.tasks.format_after_apply then
    return
  end
  vim.schedule(function()
    for _, r in ipairs(results) do
      if r.applied and r.buf ~= -1 and vim.api.nvim_buf_is_valid(r.buf) then
        local clients = vim.lsp.get_clients({ bufnr = r.buf })
        local has_formatter = false
        for _, c in ipairs(clients) do
          if c.supports_method("textDocument/formatting", r.buf) then
            has_formatter = true
            break
          end
        end
        if has_formatter then
          pcall(vim.lsp.buf.format, { bufnr = r.buf, async = false })
          vim.bo[r.buf].modified = true
          vim.api.nvim_buf_call(r.buf, function()
            pcall(vim.cmd, "write")
          end)
        end
      end
    end
  end)
end

---Default post-apply hook used by task commands: format + refresh diagnostics.
---@param results table[]
function M.after_apply(results)
  M.format_results(results)
  for _, r in ipairs(results) do
    if r.applied then
      pcall(vim.diagnostic.reset, nil)
      break
    end
  end
end

return M
