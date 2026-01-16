# falcon-measurement-lib

Central repository for measurement JSON schemas, runtime Lua helper modules, Emmy (LSP) headers, and generated Go types.

## Purpose

- Provide canonical JSON Schemas for reusable types (Domain, InstrumentTarget, ...).
- Provide per-script JSON Schemas describing globals (contexts) that measurement scripts expect.
- Provide runtime Lua modules (under `lua/falcon_measurement_lib/`) that implement helper methods referenced by schemas (e.g. InstrumentTarget:serialize).
- Generate:
  - Emmy/LSP header files for script authors (generated/emmy/)
  - Go struct types + small helpers for your compiler (generated/go-types/)
- CI packages three release artifacts per version:
  - lua-lib-<VERSION>.tar.gz — runtime Lua modules (deploy to servers)
  - go-types-<VERSION>.tar.gz — generated Go files (for compiler)
  - emmy-headers-<VERSION>.tar.gz — Emmy header files (for editor LSP)

## Quick start (developer)

- Install Go >= 1.20
- Build generated artifacts locally:
  make all
- Generated files will be placed under `generated/`. Use `generated/go-types` and `generated/emmy`.
- To package the runtime Lua library:
  make package-lua
- Use the CI workflow to create release artifacts automatically.

## Design notes

- Schemas are stored separately:
  - `schemas/lib/` — reusable type schemas (with optional `x-module` / `x-methods` vendor extensions)
  - `schemas/scripts/` — script-level context schemas (globals)
- Runtime modules are hand-authored under `lua/falcon_measurement_lib/` and deployed as the runtime library.
- The generator reads the schemas and emits Go and Emmy outputs only (no runtime Lua generation).
- The `instrument-script-server` is configured (via env var) to point to the extracted runtime library directory. It preloads modules from that directory.

See docs/ for more details on adding new schemas and modules.

## Contributing

Contributions are welcome! Please see our [contribution guidelines](CONTRIBUTING.md).

## License

See [LICENSE](LICENSE) for details.
