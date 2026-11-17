ODIN ?= odin
BIN_DIR := bin

# Build optimization profile for client/server. Valid: none (default, fastest
# compile), minimal (light optimization), speed (full optimization).
#   make client PROFILE=minimal
#   make PROFILE=speed
PROFILE ?= none

UNAME_S := $(shell uname -s)

.PHONY: all client dev server test check clean dist-windows

all: client server

# On Linux the Odin vendor binds GLFW dynamically to the system libglfw.so.3.
# Fail early with an actionable message instead of producing a binary that
# crashes with "error while loading shared libraries: libglfw.so.3".
ifneq ($(UNAME_S),Darwin)
ifneq ($(UNAME_S),)
ifeq ($(shell pkg-config --exists glfw3 && echo yes),)
$(error GLFW3 not found. Install it and retry:  sudo apt install libglfw3 libglfw3-dev pkg-config)
endif
endif
endif

client: spirv
	mkdir -p $(BIN_DIR)
	$(ODIN) build src/client -out:$(BIN_DIR)/sr_client -o:$(PROFILE)

# Developer client with debug tools (SR_DEV, F3 window). Separate file
# name so it is never packaged for testers.
dev: spirv
	mkdir -p $(BIN_DIR)
	$(ODIN) build src/client -out:$(BIN_DIR)/sr_client_dev -o:$(PROFILE) -define:SR_DEV=true

server:
	mkdir -p $(BIN_DIR)
	$(ODIN) build src/server -out:$(BIN_DIR)/sr_server -o:$(PROFILE)

test:
	# Tests are correctness checks; always compile fast with -o:none.
	mkdir -p $(BIN_DIR)
	$(ODIN) build src/tests -out:$(BIN_DIR)/sr_tests -o:none
	./$(BIN_DIR)/sr_tests

check: spirv
	$(ODIN) check src/client
	$(ODIN) check src/client -define:SR_DEV=true
	$(ODIN) check src/server

clean:
	rm -f $(BIN_DIR)/sr_client $(BIN_DIR)/sr_client_dev $(BIN_DIR)/sr_server $(BIN_DIR)/sr_tests

dist-windows: client
	@echo "Windows builds statically by default (vendor links glfw3_mt.lib); no DLL needed."
	@echo "If built with -define:GLFW_SHARED=true, copy $(shell $(ODIN) root 2>/dev/null || echo <odin-root>)/vendor/glfw/lib/glfw3.dll next to the exe."
