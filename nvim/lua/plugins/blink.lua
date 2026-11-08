return {
  "saghen/blink.cmp",
  opts = {
    completion = {
      -- Don't auto-select the first suggestion. <CR> falls through to a
      -- newline until you navigate down to an item, then Enter accepts it.
      list = { selection = { preselect = false } },
    },
  },
}
