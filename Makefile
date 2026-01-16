# Makefile for local development and CI
OUT_DIR := generated
LIB_DIR := lua
LIB_TARGET := lua-lib-$(VERSION).tar.gz
GO_TARGET := go-types-$(VERSION).tar.gz
EMMY_TARGET := emmy-headers-$(VERSION).tar.gz

VERSION := $(shell cat VERSION | tr -d '\n')

.PHONY: all generate package package-all clean

all: generate package-all

# Run the generator (requires go)
generate:
	@echo "Running generator..."
	@mkdir -p $(OUT_DIR)
	@go run ./generator/gen_from_schemas.go ./schemas/lib ./schemas/scripts $(OUT_DIR)

package: package-lua package-go package-emmy

package-lua:
	@echo "Packaging lua library..."
	@tar -czf $(LIB_TARGET) -C $(LIB_DIR) .
	@sha256sum $(LIB_TARGET) > $(LIB_TARGET).sha256
	@echo "Lua library packaged: $(LIB_TARGET)"

package-go:
	@echo "Packaging generated Go types..."
	@mkdir -p pack
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

clean:
	@rm -rf $(OUT_DIR) *.tar.gz *.sha256 pack || true
