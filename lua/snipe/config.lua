local M = {}

-- Cache env vars at load time: vim.env reads are forbidden in fast-event
-- contexts, and resolve_provider() is called from async callbacks.
local env = {
  OPENROUTER_API_KEY = vim.env.OPENROUTER_API_KEY,
  OPENAI_API_KEY = vim.env.OPENAI_API_KEY,
  SNIPE_API_KEY = vim.env.SNIPE_API_KEY,
}

local provider_presets = {
  openai = {
    kind = "openai",
    base_url = "https://api.openai.com/v1",
    model = "gpt-4o-mini",
    api_key = nil,
    timeout = 600,
    env_keys = { "OPENAI_API_KEY", "SNIPE_API_KEY" },
  },
  openrouter = {
    kind = "openai",
    base_url = "https://openrouter.ai/api/v1",
    model = "deepseek/deepseek-v4-flash",
    api_key = nil,
    timeout = 600,
    env_keys = { "OPENROUTER_API_KEY", "SNIPE_API_KEY" },
    headers = {
      "HTTP-Referer: https://github.com/luisfer-cli/snipe.nvim",
      "X-Title: snipe.nvim",
    },
  },
  ollama = {
    kind = "openai",
    base_url = "http://localhost:11434/v1",
    model = "llama3.1",
    api_key = nil,
    timeout = 600,
    env_keys = {},
  },
  lmstudio = {
    kind = "openai",
    base_url = "http://localhost:1234/v1",
    model = nil, -- the server picks a model
    api_key = nil,
    timeout = 600,
    env_keys = {},
  },
}

local defaults = {
  provider = { name = "openai" },

  context = {
    max_file_chars = 20000, -- per-file budget for current buffer / requested files
    max_context_chars = 60000, -- total budget for everything included in a prompt
    max_files = 8, -- number of extra project files included by content
    include_git_status = true,
    include_diagnostics = true,
  },

  tasks = {
    apply = "confirm", -- "confirm" | "auto"
    max_parallel = 2,
    max_reads = 6, -- max <read> file requests per task
    max_rounds = 5, -- max agent loop rounds per task
    format_after_apply = true, -- run LSP formatting after applying edits
  },

  ask = { model = nil, temperature = nil },

  temperature = 0.2,
  notify = true, -- vim.notify on task completion / errors
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
end

---@return table resolved provider settings (kind, base_url, model, api_key, timeout)
function M.resolve_provider()
  local p = M.options.provider
  if type(p) == "string" then
    p = { name = p }
  end
  p = p or {}
  local preset = provider_presets[p.name] or provider_presets.openai
  local resolved = vim.tbl_deep_extend("force", vim.deepcopy(preset), p)
  resolved.name = p.name or preset.name

  -- api_key resolution order: explicit config > env var(s) > :SnipeAuth store
  if not resolved.api_key or resolved.api_key == "" then
    resolved.api_key = nil
    for _, env_name in ipairs(preset.env_keys or {}) do
      local value = env[env_name]
      if value and value ~= "" then
        resolved.api_key = value
        break
      end
    end
  end
  if not resolved.api_key or resolved.api_key == "" then
    resolved.api_key = require("snipe.auth").get(resolved.name)
  end

  return resolved
end

---Model to use for a given mode ("task" | "ask"), falling back to the provider model.
---@param mode string
function M.model_for(mode)
  local prov = M.resolve_provider()
  local override = mode == "ask" and M.options.ask.model or nil
  return override or prov.model
end

M.presets = provider_presets

return M
