SHELL := /bin/bash
.PHONY: check syntax lint test
check: syntax lint test
syntax:
	@for script in scripts/*.sh; do bash -n "$$script" || exit; done
lint:
	shellcheck scripts/*.sh
test:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
