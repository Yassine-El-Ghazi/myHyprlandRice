# Neovim with LazyVim

Base [LazyVim](https://www.lazyvim.org/) with no optional extras or AI plugins.
The previous Kickstart setup, Copilot/Chat, debugging addons, and custom plugin
collections have been removed. LazyVim supplies editing, completion, search,
syntax highlighting, formatting, and language-server integration.

Use Neovim 0.11.2 or newer with LuaJIT. Bootstrap installs the compiler, Git,
curl, ripgrep, fd, and Tree-sitter CLI dependencies. Start `nvim` to install the
locked plugins, then run `:LazyHealth`. Use `:Lazy` to manage plugins and
`:LazyExtras` only when you want to add an optional feature.

Space is the leader key; press it and wait for the built-in keybinding menu.
Customizations belong in `lua/config/options.lua`, `keymaps.lua`, and
`autocmds.lua`. Plugin overrides belong in `lua/plugins/`.

The plugin manager and LazyVim follow stable releases. Update checks notify you;
run `:Lazy update` to install updates together. The lockfile records the core
plugin revisions; commit its changes when adopting an update. Project `.lazy.lua` specs,
exrc files, and modelines are disabled. `luals-safe.json` and `config/luals.lua`
preserve the audit's server-side restriction on executable project plugins,
third-party addons, and documentation scripts. A missing or invalid policy
prevents LuaLS startup.

Ordinary registers stay local to Neovim. Use `"+y` or `"+p` for explicit desktop
clipboard operations; copied text can still be collected by desktop history.
Undo works while a buffer is open. Persistent undo, swap files, ShaDa, and
automatic session saving are disabled for every buffer, so editing a private
file does not depend on recognizing its filename. This reduces crash recovery
and removes automatic session restoration. The session-persistence plugin is
disabled; no privacy addon is installed.

These options prevent new editor-state copies. They do not delete existing
undo, swap, ShaDa, session files, or backups. Restart Neovim after installing
the updated configuration. Use `:Lazy clean` to remove disabled cached plugins.
