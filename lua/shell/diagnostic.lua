-- vim.diagnostic backend for shell#compat#diagnostic().
local M = {}

local ns = vim.api.nvim_create_namespace('shell.diagnostic')

-- Replace diagnostics on lines l1..l2 (1-based) with msg at l1, if any.
function M.set(buf, l1, l2, msg)
  local diags = vim.tbl_filter(function(d)
    return d.lnum < l1 - 1 or d.lnum > l2 - 1
  end, vim.diagnostic.get(buf, { namespace = ns }))
  if msg ~= '' then
    table.insert(diags, { lnum = l1 - 1, col = 0, message = msg, severity = vim.diagnostic.severity.ERROR, source = 'shell' })
  end
  vim.diagnostic.set(ns, buf, diags)
end

function M.get(buf)
  local diags = vim.diagnostic.get(buf, { namespace = ns })
  table.sort(diags, function(a, b) return a.lnum < b.lnum end)
  return vim.tbl_map(function(d) return { d.lnum + 1, d.message } end, diags)
end

return M
