if vim.g.loaded_git_panel then return end
vim.g.loaded_git_panel = true

vim.api.nvim_create_user_command("GitPanel", function()
  require("git_panel").open("tab")
end, { desc = "Open Git Panel in a tab" })

vim.api.nvim_create_user_command("GitPanelSplit", function()
  require("git_panel").open("split")
end, { desc = "Open Git Panel as a left split" })

vim.api.nvim_create_user_command("GitPanelConnection", function(options)
  require("git_panel").select_connection(options.args ~= "" and options.args or nil)
end, {
  desc = "Select a configured GitPanel GitHub connection",
  nargs = "?",
  complete = function()
    return require("git_panel").connection_profile_names()
  end,
})

vim.api.nvim_create_user_command("GitPanelDoctor", function()
  require("git_panel").connection_doctor()
end, { desc = "Diagnose the GitPanel GitHub connection" })
