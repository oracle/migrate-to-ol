SHELL := /bin/bash

.PHONY: check shellcheck syntax

check: syntax shellcheck

syntax:
	bash -n migrate-to-oracle-linux.sh
	bash -n mirror-oracle-linux-yum.sh

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck migrate-to-oracle-linux.sh mirror-oracle-linux-yum.sh; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi
