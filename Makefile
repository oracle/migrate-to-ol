SHELL := /bin/bash

.PHONY: check shellcheck syntax test

check: syntax shellcheck test

syntax:
	bash -n migrate-to-oracle-linux.sh
	bash -n mirror-oracle-linux-yum.sh
	bash -n tests/*.sh

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck migrate-to-oracle-linux.sh mirror-oracle-linux-yum.sh tests/*.sh; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

test:
	@for test_script in tests/test-*.sh; do \
		bash "$$test_script"; \
	done
