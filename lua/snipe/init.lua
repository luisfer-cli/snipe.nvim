local M = {}

local config = require("snipe.config")
local tasks = require("snipe.tasks")

M.config = config
M.tasks = tasks

---@param opts table?
---@return table
function M.setup(opts)
  config.setup(opts or {})

  require("snipe.ui.panel").setup()
  require("snipe.ui.ask").setup()
  require("snipe.statusline").watch()

  vim.api.nvim_create_user_command("Snipe", function()
    M.panel_toggle()
  end, { desc = "Toggle the snipe task panel" })

  vim.api.nvim_create_user_command("SnipePanel", function()
    require("snipe.ui.panel").open()
  end, { desc = "Open the snipe task panel" })

  vim.api.nvim_create_user_command("SnipeAsk", function(a)
    M.ask(a.args, a.line1, a.line2)
  end, { nargs = "*", range = true, desc = "Ask a question about the project (async)" })

  vim.api.nvim_create_user_command("SnipeTask", function(a)
    M.task(a.args, a.line1, a.line2)
  end, { nargs = "*", range = true, desc = "Leave the AI working on a task (async)" })

  vim.api.nvim_create_user_command("SnipeKill", function(a)
    M.kill(a.args)
  end, { nargs = "?", desc = "Kill the running task (or a specific id)" })

  vim.api.nvim_create_user_command("SnipeApply", function(a)
    if a.args ~= "" then
      M.apply(a.args)
    else
      M.apply_review()
    end
  end, { nargs = "?", desc = "Apply pending edits (task id or most recent review)" })

  vim.api.nvim_create_user_command("SnipeRevert", function(a)
    M.revert(a.args)
  end, { nargs = "?", desc = "Revert edits applied by a task" })

  vim.api.nvim_create_user_command("SnipeAuth", function(a)
    require("snipe.auth").command(a.args)
  end, { nargs = "?", desc = "Store the API key for a provider (default: current)" })

  vim.api.nvim_create_user_command("SnipeAuthRemove", function(a)
    require("snipe.auth").command_remove(a.args)
  end, { nargs = "?", desc = "Remove the stored API key for a provider" })

  -- highlight groups
  vim.api.nvim_set_hl(0, "SnipePanelSelected", { default = true, link = "Visual" })

  return M
end

---Capture a visual/command range as a code block ("" when no range).
---@param line1 integer
---@param line2 integer
---@return string
local function selection_block(line1, line2)
  if not line1 or not line2 or line1 <= 0 or line1 > line2 then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  if #lines == 0 then
    return ""
  end
  local ft = vim.bo[0].filetype
  return ("\n\nSelected code (lines %d-%d):\n```%s\n%s\n```"):format(line1, line2, ft, table.concat(lines, "\n"))
end

---Ask a question about the project.
---@param question string?
---@param line1 integer? visual range start
---@param line2 integer? visual range end
function M.ask(question, line1, line2)
  local selection = selection_block(line1, line2)
  local function run(q)
    q = q:gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then
      return
    end
    q = q .. selection
    require("snipe.ui.ask").ask(q)
  end
  if question and question ~= "" then
    run(question)
  else
    vim.ui.input({
      prompt = selection == "" and "snipe ask: " or "snipe ask (about selection): ",
    }, function(input)
      if input then
        run(input)
      end
    end)
  end
end

---Parse leading apply-mode flags from a task prompt.
---@param args string
---@return string apply, string prompt
local function parse_task_args(args)
  local apply = config.options.tasks.apply or "confirm"
  local rest = args
  if rest:match("^%-%-auto") or rest:match("^%-a") then
    apply = "auto"
    rest = rest:gsub("^%-%-auto%s*", ""):gsub("^%-a%s*", "")
  elseif rest:match("^%-%-confirm") then
    apply = "confirm"
    rest = rest:gsub("^%-%-confirm%s*", "")
  end
  return apply, rest
end

---Leave the AI working on a task.
---@param args string
---@param line1 integer? visual range start
---@param line2 integer? visual range end
function M.task(args, line1, line2)
  local apply, prompt = parse_task_args(args)
  prompt = prompt:gsub("^%s+", ""):gsub("%s+$", "")
  local selection = selection_block(line1, line2)

  local function run(p)
    if p == "" then
      return
    end
    local name = p:gsub("%s+", " "):sub(1, 40)
    tasks.create({
      kind = "task",
      name = name,
      prompt = p .. selection,
      apply = apply,
    })
  end

  if prompt ~= "" then
    run(prompt)
  else
    local hint = selection == "" and ("snipe task [%s]: "):format(apply)
      or ("snipe task [%s] (about selection): "):format(apply)
    vim.ui.input({ prompt = hint }, function(input)
      if input then
        run(input)
      end
    end)
  end
end

---@param id string?
function M.kill(id)
  return tasks.kill(id == "" and nil or id)
end

---@param id string?
function M.apply(id)
  return tasks.apply(id == "" and nil or id)
end

---@param id string?
function M.revert(id)
  return tasks.revert(id == "" and nil or id)
end

---Apply the most recent task in review state.
function M.apply_review()
  local list = tasks.list()
  for i = #list, 1, -1 do
    if list[i].status == "review" then
      tasks.apply(list[i].id)
      return
    end
  end
  vim.notify("no task waiting for review", vim.log.levels.INFO, { title = "snipe" })
end

---Toggle the task panel.
function M.panel_toggle()
  require("snipe.ui.panel").toggle()
end

---Statusline component.
function M.statusline()
  return require("snipe.statusline").component()
end

---Log the most recent task (debug helper).
function M.log()
  local list = tasks.list()
  if #list > 0 then
    tasks.open_log(list[#list].id)
  end
end

return M
