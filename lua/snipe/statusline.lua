local M = {}

---Statusline component. Returns "" when nothing is active.
---Example (lualine): { function() return require("snipe").statusline() end }
---@return string
function M.component()
  local tasks = require("snipe.tasks")
  local running, review, queued = 0, 0, 0
  local current = nil

  for _, t in ipairs(tasks.list()) do
    if t.status == "running" then
      running = running + 1
      if not current then
        current = t.status_msg or ""
      end
    elseif t.status == "review" then
      review = review + 1
    elseif t.status == "queued" then
      queued = queued + 1
    end
  end

  local parts = {}
  if running > 0 then
    table.insert(parts, ("⚡%d"):format(running))
    if current and current ~= "" then
      table.insert(parts, current:gsub("%s+", " "):sub(1, 24))
    end
  end
  if queued > 0 then
    table.insert(parts, ("⋯%d"):format(queued))
  end
  if review > 0 then
    table.insert(parts, ("✋%d"):format(review))
  end
  return table.concat(parts, " ")
end

---Hook that keeps the statusline fresh. Call once from setup.
function M.watch()
  vim.api.nvim_create_autocmd("User", {
    pattern = "SnipeTaskUpdated",
    callback = function()
      vim.cmd("redrawstatus")
    end,
  })
end

return M
