PREFIX ?= $(HOME)/.local/bin

.PHONY: install
install:
	install -d $(PREFIX)
	install -m 0755 scripts/claude-container $(PREFIX)/claude-container
	ln -f $(PREFIX)/claude-container $(PREFIX)/codex-container
	ln -f $(PREFIX)/claude-container $(PREFIX)/gemini-container
