-- Find the command under the cursor with the treesitter bash parser.
local M = {}

function M.available()
  return (pcall(vim.treesitter.language.add, 'bash'))
end

-- Line range {start, end} (1-based) of the top-level command(s) at lnum, or
-- nil when treesitter can't tell (no parser, parse error, comment, blank).
function M.range(buf, lnum)
  if not M.available() then
    return nil
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'bash')
  if not ok or not parser then
    return nil
  end
  local nodes = {}
  for node in parser:parse()[1]:root():iter_children() do
    local sr, _, er, ec = node:range()
    if ec == 0 and er > sr then
      er = er - 1
    end
    table.insert(nodes, { node = node, s = sr + 1, e = er + 1 })
  end
  -- Grow to every node sharing a line with the range (`a; b` is one run).
  local s, e = lnum, lnum
  local found, grown = false, true
  while grown do
    grown = false
    for _, n in ipairs(nodes) do
      if n.s <= e and s <= n.e and n.node:type() ~= 'comment' and not n.seen then
        n.seen, found, grown = true, true, true
        if n.node:has_error() then
          return nil
        end
        s, e = math.min(s, n.s), math.max(e, n.e)
      end
    end
  end
  return found and { s, e } or nil
end

return M
