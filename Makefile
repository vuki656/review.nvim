DEPS_DIR = .deps
MINI_NVIM = $(DEPS_DIR)/mini.nvim

.PHONY: test test-file deps

deps: $(MINI_NVIM)

$(MINI_NVIM):
	@mkdir -p $(DEPS_DIR)
	git clone --depth 1 https://github.com/echasnovski/mini.nvim $(MINI_NVIM)

test: $(MINI_NVIM)
	nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run()"

test-file: $(MINI_NVIM)
	nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"
