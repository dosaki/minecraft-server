.PHONY: test lint fmt
test:
	python3 -m pytest -q
lint:
	shellcheck server/bin/*.sh scripts/*.sh
	terraform fmt -check -recursive
fmt:
	terraform fmt -recursive
