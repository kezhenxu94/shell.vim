.PHONY: test test-e2e demo

# Headless, in Vim and Neovim
test:
	test/run.sh

# Vim and Neovim in tmux, driven with the default mappings
test-e2e:
	test/e2e.sh

# The README demo: needs tmux, jq, asciinema 3 and agg
demo:
	demo/record.sh
