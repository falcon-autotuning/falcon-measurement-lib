# falcon-measurement-lib

Central repository for measurement JSON schemas, runtime Lua helper modules, Emmy (LSP) headers, and generated Go types.

## Purpose

- Provide canonical JSON Schemas for reusable types (Domain, InstrumentTarget, ...).
- Provide per-script JSON Schemas describing globals (contexts) that measurement scripts expect.
- Provide runtime Lua modules (under `lua/falcon_measurement_lib/`) that implement helper methods referenced by schemas (e.g. InstrumentTarget:serialize).
- Generate:
  - Emmy/LSP header files for script authors (generated/emmy/)
  - Go struct types + small helpers for your compiler (generated/go-types/)
  - Teal (statically typed Lua) script scaffolds with expanded-parameter `main` signatures (generated/teal/) — optional, produced when the Teal emitter is available.
- CI packages three release artifacts per version:
  - lua-lib-<VERSION>.tar.gz — runtime Lua modules (deploy to servers)
  - go-types-<VERSION>.tar.gz — generated Go files (for compiler)
  - emmy-headers-<VERSION>.tar.gz — Emmy header files (for editor LSP)

## New: Teal integration and typed script returns

This repository now supports generating Teal scaffolds for script schemas. The new features are:

- Teal scaffolds are emitted into `generated/teal/scripts/` as `.teal` files. Each script schema becomes a Teal file that:
  - Declares the shared `RuntimeContext` record.
  - Emits expanded-parameter `function main(ctx: RuntimeContext, ...)` signatures (one parameter per script schema property).
  - Emits a typed return signature derived from the schema's top-level `returns` JSON Schema (see below).
  - References runtime Teal modules (if present) instead of duplicating type definitions. If a runtime `.teal` module is not present for a referenced type (e.g. `InstrumentTarget`), a minimal `record` stub will be emitted so the generated Teal still typechecks.

- Script-level `returns` support:
  - Script JSON schemas can include a top-level `returns` node describing what `main` should return.
  - Typical convention used by the emitter:
    - Non-buffered scripts (single-value per getter) should use:
      "returns": { "type": "object", "additionalProperties": { "type": "number" } }
      which maps to Teal: `{ [string]: number }`
    - Buffered scripts (per-getter arrays) should use:
      "returns": { "type": "object", "additionalProperties": { "type": "array", "items": {"type":"number"} } }
      which maps to Teal: `{ [string]: { number } }` (a map of string -> array of numbers)
  - The generator emits a `-- @return` docline and a typed function return in the Teal scaffold, e.g.:
    function main(ctx: RuntimeContext, bufferedGetters: {InstrumentTarget}, sampleRate: number): { [string]: { number } }

- Backwards compatibility & why keys are strings:
  - Return maps are keyed by string identifiers (e.g. serialized InstrumentTarget ids). InstrumentTarget objects are typically serialized at runtime (see `InstrumentTarget:serialize`) and string-keyed maps are interoperable with Lua and Teal indexer types.
  - If you prefer a different key type (e.g. indexer keyed by a record type), we can adjust the emitter, but string keys are the conventional and robust choice.

## Quick start (developer)

- Build generated artifacts locally:
  make all
- Generated files will be placed under `generated/`. Use:
  - `generated/go-types`
  - `generated/emmy`
  - `generated/teal` (if Teal emitter is available)
- To package the runtime Lua library:
  make package-lua
- Use the CI workflow to create release artifacts automatically.

## Generator invocation & options

The generator entrypoint remains `generator/gen_from_schemas.lua`. The CLI signature:

lua generator/gen_from_schemas.lua <lib-schemas-dir> <script-schemas-dir> <source-lua-dir> <out-dir> [--no-generated-lua]

- `--no-generated-lua` — when provided, the generator will skip producing the `generated/lua/` implementation files and will only emit the editor/interop artifacts (Emmy headers, Go types, and Teal scaffolds if available). This is useful when you only want type headers and Teal scaffolds without duplicating runtime Lua implementations.

Makefile integration:

- By default `make generate` will call the generator as before. If you want `make generate` to skip generating Lua implementation files and only produce headers + Teal scaffolds, edit the `generate` target to pass `--no-generated-lua` to the generator invocation.

## Adding script return types to schemas

- To get typed returns in the generated Teal, add a `returns` entry to your script schema JSON file (top-level), for example:

Non-buffered single numeric value per getter:

```json
"returns": {
  "type": "object",
  "description": "Map from getter identifier to a numeric measured value (float).",
  "additionalProperties": {
    "type": "number"
  }
}
```

Buffered per-getter numeric array:

```json
"returns": {
  "type": "object",
  "description": "Map from getter identifier to an array of numeric values (buffered).",
  "additionalProperties": {
    "type": "array",
    "items": { "type": "number" }
  }
}
```

- There is a helper script to add `returns` to existing script schemas via a conservative heuristic (it creates `.bak` backups). See `generator/patch_schemas_add_returns.lua`.

## Teal toolchain and CI

- To validate generated Teal in CI or locally:
  - Install the Teal tool (`tl`) and the Teal language server:
    - tl: <https://github.com/teal-language/tl>
    - `teal-language-server` (npm or from repo)
  - Run:
    tl check generated/teal/scripts/*.teal
- Recommended CI job:
  - After generation, run `tl check` on the `generated/teal` directory and fail the build if there are type errors.

## Notes

- The Go generation remains unchanged.
- The Teal emitter uses the same canonical schemas and `definitions` as Go and Emmy generation — there is one source of truth.
- The Teal emitter will avoid duplicating types when a runtime Teal module exists for a referenced type; prefer adding `.teal` runtime modules to `lua/falcon_measurement_lib/` if you want canonical type definitions used by the generated scaffolds.

## Contributing

Contributions are welcome! Please see our [contribution guidelines](CONTRIBUTING.md).

## License

See [LICENSE](LICENSE) for details.
