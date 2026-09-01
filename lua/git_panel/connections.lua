local M = {}

M.default_id = 'default'

local PROFILE_METADATA = {
  label = true,
  description = true,
  profile = true,
  profiles = true,
}

local function copy_without_metadata(profile)
  local overrides = {}
  for key, value in pairs(profile or {}) do
    if not PROFILE_METADATA[key] then overrides[key] = vim.deepcopy(value) end
  end
  return overrides
end

local function profiles(config)
  local configured = config and config.profiles or {}
  if type(configured) ~= 'table' then
    return nil, 'github.profiles must be a table keyed by profile name'
  end
  for id, profile in pairs(configured) do
    if type(id) ~= 'string' or id == '' or id == M.default_id then
      return nil, 'github.profiles keys must be non-empty strings other than "default"'
    end
    if type(profile) ~= 'table' then
      return nil, 'github.profiles.' .. tostring(id) .. ' must be a table'
    end
  end
  return configured
end

function M.resolve(config, requested)
  config = vim.deepcopy(config or {})
  local configured, profiles_error = profiles(config)
  if not configured then return nil, profiles_error end

  local selected = requested
  if selected == nil then selected = config.profile end
  if selected == '' or selected == M.default_id then selected = nil end
  if selected ~= nil and type(selected) ~= 'string' then
    return nil, 'github.profile must be a profile name or nil'
  end

  local effective = vim.deepcopy(config)
  if selected then
    local profile = configured[selected]
    if not profile then
      return nil, ('github.profile %q is not defined in github.profiles'):format(selected)
    end
    effective = vim.tbl_deep_extend('force', effective, copy_without_metadata(profile))
  end
  effective.profile = selected
  effective.profiles = vim.deepcopy(configured)
  return effective
end

function M.label(config, id)
  if id == nil or id == '' or id == M.default_id then return 'Default / automatic' end
  local configured = type(config and config.profiles) == 'table' and config.profiles or {}
  local profile = configured[id]
  if type(profile) == 'table' and type(profile.label) == 'string' and profile.label ~= '' then
    return profile.label
  end
  return id
end

function M.choices(config, active)
  local configured, profiles_error = profiles(config or {})
  if not configured then return nil, profiles_error end
  local choices = {
    {
      id = M.default_id,
      label = M.label(config, nil),
      description = 'Use the base github settings from setup().',
      active = active == nil or active == '' or active == M.default_id,
    },
  }
  local ids = {}
  for id in pairs(configured) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local profile = configured[id]
    choices[#choices + 1] = {
      id = id,
      label = M.label(config, id),
      description = type(profile.description) == 'string' and profile.description or nil,
      active = active == id,
    }
  end
  return choices
end

return M
