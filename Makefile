PREFIX ?= $(HOME)/.local/bin

.PHONY: install
install:
	install -d $(PREFIX)
	install -m 0755 scripts/claude-container $(PREFIX)/claude-container
	ln -f $(PREFIX)/claude-container $(PREFIX)/codex-container
	ln -f $(PREFIX)/claude-container $(PREFIX)/gemini-container
	install -m 0755 scripts/op-claude $(PREFIX)/op-claude
	ln -f $(PREFIX)/op-claude $(PREFIX)/op-codex
	ln -f $(PREFIX)/op-claude $(PREFIX)/op-gemini
