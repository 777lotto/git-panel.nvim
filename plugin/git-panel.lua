if vim.g.loaded_git_panel then return end
vim.g.loaded_git_panel = true

vim.api.nvim_create_user_command("GitPanel", function()
  require("git_panel").open("tab")
end, { desc = "Open Git Panel in a tab" })

vim.api.nvim_create_user_command("GitPanelSplit", function()
  require("git_panel").open("split")
end, { desc = "Open Git Panel as a left split" })
