SHELL := /bin/zsh
APP := build/ResetCardBar.app
BIN := $(APP)/Contents/MacOS/ResetCardBar

.PHONY: build test run preview health package
build:
	./scripts/build.sh

test: build
	"$(BIN)" --self-test
	"$(BIN)" --monitor-tests
	python3 tests/test_rpc.py "$(BIN)"

run: build
	open "$(APP)"

preview: build
	open "$(APP)" --args --preview

health:
	"$(BIN)" --health-check

package: test
	./scripts/package.sh
