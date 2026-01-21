# Makefile (updated to call Lua generator)
OUT_DIR := generated
SRC_LUA_DIR := lua
LIB_TARGET := lua-lib-$(VERSION).tar.gz
GO_TARGET := go-types-$(VERSION).tar.gz
EMMY_TARGET := emmy-headers-$(VERSION).tar.gz

VERSION := $(shell cat VERSION | tr -d '\n')
LUA_VENV := .lua_venv
LUA_VENV_BIN := $(LUA_VENV)/bin
LUA_VENV_TREE := $(LUA_VENV)/lua_modules

.PHONY: all generate package package-all clean venv venv-clean

all: venv generate package-all

venv:
	@echo "Setting up Lua venv in $(LUA_VENV)..."
	@mkdir -p $(LUA_VENV_BIN)
	@mkdir -p $(LUA_VENV_TREE)
	@echo '#!/bin/sh' > $(LUA_VENV_BIN)/lua
	@echo 'LUA_PATH="$(LUA_VENV_TREE)/share/lua/5.4/?.lua;$(LUA_VENV_TREE)/share/lua/5.4/?/init.lua;;" LUA_CPATH="$(LUA_VENV_TREE)/lib/lua/5.4/?.so;;" exec lua "$$@"' >> $(LUA_VENV_BIN)/lua
	@chmod +x $(LUA_VENV_BIN)/lua
	@echo '#!/bin/sh' > $(LUA_VENV_BIN)/luarocks
	@echo 'LUAROCKS_TREE="$(LUA_VENV_TREE)" exec luarocks --tree="$(LUA_VENV_TREE)" "$$@"' >> $(LUA_VENV_BIN)/luarocks
	@chmod +x $(LUA_VENV_BIN)/luarocks
	@echo "Installing Lua dependencies (dkjson, luafilesystem)..."
	@$(LUA_VENV_BIN)/luarocks install dkjson
	@$(LUA_VENV_BIN)/luarocks install luafilesystem
	@echo "Lua venv created. Use $(LUA_VENV_BIN)/luarocks to install modules."

venv-clean:
	@rm -rf $(LUA_VENV)

generate: venv
	@echo "Running Lua generator..."
	@mkdir -p $(OUT_DIR)
	@LUA_PATH="$(LUA_VENV_TREE)/share/lua/5.4/?.lua;$(LUA_VENV_TREE)/share/lua/5.4/?/init.lua;;" LUA_CPATH="$(LUA_VENV_TREE)/lib/lua/5.4/?.so;;" $(LUA_VENV_BIN)/lua ./generator/gen_from_schemas.lua ./schemas/lib ./schemas/scripts $(SRC_LUA_DIR) $(OUT_DIR)

package-lua:
	@echo "Packaging generated lua library..."
	@tar -czf $(LIB_TARGET) -C $(OUT_DIR)/lua .
	@sha256sum $(LIB_TARGET) > $(LIB_TARGET).sha256
	@echo "Lua library packaged: $(LIB_TARGET)"

package-go:
	@echo "Packaging generated Go types..."
	@tar -czf $(GO_TARGET) -C $(OUT_DIR)/go-types .
	@sha256sum $(GO_TARGET) > $(GO_TARGET).sha256
	@echo "Go types packaged: $(GO_TARGET)"

package-emmy:
	@echo "Packaging emmy headers..."
	@tar -czf $(EMMY_TARGET) -C $(OUT_DIR)/emmy .
	@sha256sum $(EMMY_TARGET) > $(EMMY_TARGET).sha256
	@echo "Emmy headers packaged: $(EMMY_TARGET)"

package-all: package-lua package-go package-emmy
	@echo "All packages generated for version $(VERSION)."

clean: venv-clean
	@rm -rf $(OUT_DIR) *.tar.gz *.sha256 || true
