# Usage & Editor Integration

This document describes how to use the generator and how to work with editor tooling (Emmy LSP / Teal LSP) to author measurement scripts.

## Generator

The generator reads two schema directories and emits multiple outputs:

- Reusable type schemas: `schemas/lib/`
- Script-level schemas: `schemas/scripts/`

Run the generator:

- Default (produces generated/lua implementations, Emmy headers, Go types, and Teal if emitter present)
  lua generator/gen_from_schemas.lua ./schemas/lib ./schemas/scripts ./lua ./generated

- Skip generating `generated/lua/` (emit only headers, go-types, and teal):
  lua generator/gen_from_schemas.lua ./schemas/lib ./schemas/scripts ./lua ./generated --no-generated-lua

After running the generator the following directories are produced under `<out-dir>`:

- generated/emmy/ — editor-only Emmy header files for Lua LSP users
- generated/go-types/ — generated Go types
- generated/teal/scripts/ — generated Teal scaffolds (if generator/teal_emitter.lua is present)
- generated/lua/ — generated Lua implementations (unless `--no-generated-lua` was passed)

## New: Teal scaffolds

When the Teal emitter is present, for each script schema in `schemas/scripts/` the generator emits a `.teal` scaffold:

- Expanded-parameter `main` function:
  - Each schema property becomes an explicit parameter on `main(ctx, ...)`.
  - Example:
    function main(ctx: RuntimeContext, gesture: InstrumentTarget, sampleRate: number): { [string]: number }

- Typed returns:
  - If your script schema defines a top-level `returns` JSON Schema, the Teal main signature will include the return type derived from that schema.
  - Use `returns` with `additionalProperties` to model maps keyed by getter identifiers:
    - Single numeric value per getter:
      "returns": { "type": "object", "additionalProperties": { "type": "number" } }
    - Buffered array per getter:
      "returns": { "type": "object", "additionalProperties": { "type": "array", "items": { "type": "number" } } }

- Runtime type linking:
  - If you provide runtime `.teal` modules (e.g., `lua/falcon_measurement_lib/instrument_target.teal`), the Teal emitter will reference those modules instead of emitting record stubs. Otherwise minimal `record` stubs are emitted in the generated file.

## Editor setup

- For Lua/Emmy users (sumneko / lua-language-server):
  - Place `generated/emmy/` in an indexed path (project root or workspace) so the LSP can pick up `---@class` and `---@field` annotations.
- For Teal users:
  - Install `tl` and `teal-language-server`.
  - Open the generated `generated/teal` files in your editor workspace so the Teal LSP can provide autocompletion and hover information.

## Adding `returns` to existing schemas

We provide a small helper that adds a conservative `returns` block to schemas under `schemas/scripts/`:

- `generator/patch_schemas_add_returns.lua`

Usage:

- Install required Lua modules (dkjson or cjson + luafilesystem) or use the project venv.
- Run:
  lua generator/patch_schemas_add_returns.lua schemas/scripts

- The helper:
  - Skips files that already define `returns`.
  - If a schema has any property whose name contains `"buffered"` (case-insensitive) it will add a buffered returns (map of arrays of numbers).
  - Otherwise it will add a single-value returns (map of numbers).
  - The script writes a `.bak` backup for each file it modifies — review backups before committing.

## CI recommendations

- Add a CI step to run generation and then:
  - tl check generated/teal/scripts/*.teal  (fail build if type errors)
  - Optionally run `tl check` only when teal emitter is available or when a certain flag is set.
- Keep `make generate` in CI and optionally use `--no-generated-lua` if you do not want to publish duplicated Lua implementation files.

## Examples

- Example script schema snippet with returns (non-buffered):

```json
{
  "title": "Get_Voltage",
  "type": "object",
  "properties": {
    "getter": {
      "$ref": "../lib/instrument_target.json#/definitions/InstrumentTarget",
      "description": "Instrument to collect applied voltage from"
    }
  },
  "returns": {
    "type": "object",
    "additionalProperties": { "type": "number" },
    "description": "Map from getter identifier to numeric measured value"
  }
}
```

- Generated Teal signature (example):

```teal
function main(ctx: RuntimeContext, getter: InstrumentTarget): { [string]: number }
```

## Support and feedback

If you hit issues integrating Teal into your workflow or have opinions about key types (string vs record) for return maps, open an issue or a PR — we'll iterate on the conventions to match your runtimes and editors.
