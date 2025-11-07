.PHONY: build install clean test

VERSION := $(shell scripts/version.bash)
DIST := dist
BUILD_ARTIFACT := $(DIST)/px
INSTALL_DIR ?= $(HOME)/.local/bin

build: $(BUILD_ARTIFACT)

$(DIST):
	mkdir -p $(DIST)

$(BUILD_ARTIFACT): px.bash scripts/version.bash | $(DIST)
	sed "s/{{PX_VERSION_FROM_GIT}}/$(VERSION)/" px.bash > $(BUILD_ARTIFACT)
	chmod +x $(BUILD_ARTIFACT)

install: build
	install -d "$(INSTALL_DIR)"
	install $(BUILD_ARTIFACT) "$(INSTALL_DIR)/px"
	@echo "px $(VERSION) installed to $(INSTALL_DIR)/px"

clean:
	rm -rf $(DIST)

test:
	./scripts/test.bash
