-- You can add your own plugins here or in other files in this directory!
--  I promise not to create any merge conflicts in this directory :)
--
-- See the kickstart.nvim README for more information

return {
  ---------------------------------------------------------------------------
  -- GitHub Copilot (core engine, inline suggestions ONLY)
  ---------------------------------------------------------------------------
  {
    'zbirenbaum/copilot.lua',
    cmd = 'Copilot',
    event = 'InsertEnter',
    opts = {
      suggestion = {
        enabled = true,
        auto_trigger = true,
        keymap = {
          accept = false, -- disable <Tab>
          next = false,
          prev = false,
          dismiss = false,
        },
      },
      panel = { enabled = false },
    },
  },

  ---------------------------------------------------------------------------
  -- Copilot Chat (chat UI, diffs, tools, prompts)
  ---------------------------------------------------------------------------
  {
    'CopilotC-Nvim/CopilotChat.nvim',
    dependencies = {
      { 'zbirenbaum/copilot.lua' }, -- MUST use the Lua Copilot
      { 'nvim-lua/plenary.nvim' },
    },
    build = 'make tiktoken',
    opts = {
      model = 'gpt-4.1',
      temperature = 0.1,
      auto_insert_mode = true,
      window = {
        layout = 'vertical',
        width = 0.45,
      },
    },
  },
}
