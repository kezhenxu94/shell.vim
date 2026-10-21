-- :checkhealth shell
local M = {}

function M.check()
  local h = vim.health
  h.start('shell.vim')
  for _, exe in ipairs({ 'bash', 'zsh' }) do
    if vim.fn.executable(exe) == 1 then
      h.ok(exe .. ': ' .. vim.fn.exepath(exe))
    else
      h.warn(exe .. ' not found: scripts for it cannot run')
    end
  end
  if vim.fn.executable('pgrep') == 1 then
    h.ok('pgrep found (used by :Sh interrupt)')
  else
    h.error('pgrep not found: :Sh interrupt cannot stop runs')
  end
  if vim.fn.executable('git') == 1 then
    h.ok('git found (session cwd is the repository root)')
  else
    h.info('git not found: sessions start in the file\'s directory')
  end
  if require('shell.ts').available() then
    h.ok('treesitter bash parser found')
  else
    h.info('no treesitter bash parser: using the built-in command scanner')
  end
end

return M
