# Usage & Editor Integration

This document describes how to use the generator and how to work with editor tooling (Emmy LSP / Teal LSP) to author measurement scripts. It also documents the generator's strict conventions for script-level `returns` so the generated Teal and Go artifacts remain consistent and type-safe.

## Generator

The generator reads two schema directories and emits multiple outputs:

- Reusable type schemas: `schemas/lib/`
- Script-level schemas: `schemas/scripts/`

Run the generator

- Default (produces generated/lua implementations, Emmy headers, Go types, and Teal if emitter present)

  ```
  lua generator/gen_from_schemas.lua ./schemas/lib ./schemas/scripts ./lua ./generated
  ```

- Skip generating `generated/lua/` (emit only headers, go-types, and teal):

  ```
  lua generator/gen_from_schemas.lua ./schemas/lib ./schemas/scripts ./lua ./generated --no-generated-lua
  ```

After running the generator the following directories are produced under `<out-dir>`:

- `generated/emmy/` — editor-only Emmy header files for Lua LSP users
- `generated/go-types/` — generated Go types (requests, responses, measurement wrappers, helpers)
- `generated/teal/scripts/` — generated Teal scaffolds (if `generator/teal_emitter.lua` is present)
- `generated/lua/` — generated Lua implementations (unless `--no-generated-lua` was passed)

Makefile integration:

```
make generate
```

still invokes the generator with the same CLI signature; no Makefile changes are required.

## New: strict returns convention (preferred pattern)

To keep Teal and Go generation consistent, the generator now enforces a single canonical form for script `returns`:

- Preferred: the script `returns` MUST be expressed using an `allOf` that combines the canonical `MeasurementResponse` definition (via `$ref`) and a small annotation object that specifies the concrete value type with the `x-valueType` key.

Two supported shapes (strict):

- Array of MeasurementResponse (collection):

  ```json
  "returns": {
    "type": "array",
    "items": {
      "allOf": [
        { "$ref": "../lib/measurement_response.json#/definitions/MeasurementResponse" },
        { "x-valueType": "number" }
      ]
    }
  }
  ```

  This maps to: Teal `MeasurementResponses<number>` and Go `[]MeasurementResponseNumber` (concrete struct `MeasurementResponseNumber`).

- Single MeasurementResponse (single value):

  ```json
  "returns": {
    "allOf": [
      { "$ref": "../lib/measurement_response.json#/definitions/MeasurementResponse" },
      { "x-valueType": "number" }
    ]
  }
  ```

  This maps to: Teal `MeasurementResponse<number>` and Go `MeasurementResponseNumber` (concrete struct).

- No returns: It is valid to omit `returns` entirely for scripts that do not return a value. The generator will interpret "no returns" as `: nil` in Teal and as an empty Go response struct.

Important: the generator enforces these patterns strictly. If a script schema includes a `returns` node but it does not match one of the preferred patterns above (for example: `additionalProperties`-style returns, or ad-hoc `$ref` without `x-valueType`), generation will fail loudly with an error. This keeps all downstream artifacts consistent.

### Why an `x-valueType` annotation?

JSON Schema has no generics. The `MeasurementResponse` is a wrapper type whose `value` field can be different primitives (number, string, boolean, buffer). We annotate the instance with `x-valueType` (e.g. `"number"`) to declare the concrete type for code generation.

### Canonical measurement definition

Place the canonical wrapper at:
`lib/measurement_response.json#/definitions/MeasurementResponse`
(Example included in the repo.)

## Teal scaffolds

When the Teal emitter is present, each script schema in `schemas/scripts/` becomes a `.tl` scaffold in `generated/teal/scripts/`.

- Expanded-parameter `main` function:
  - Each schema property becomes an explicit parameter on `main(ctx, ...)`.
  - Example (single measurement return):

    ```teal
    local function Get_Number_Of_Samples(ctx: RuntimeContext, getter: InstrumentTarget): MeasurementResponse<number>
    ```

  - Example (array of measurements):

    ```teal
    local function Get_All_Voltages(ctx: RuntimeContext, getters: { [number]: InstrumentTarget }): MeasurementResponses<number>
    ```

- Typed returns:
  - The Teal emitter derives the return type only from the strict preferred `allOf + x-valueType` pattern.
  - If `returns` is omitted the scaffold returns `: nil`.

- Runtime type linking:
  - If runtime `.tl` modules exist under your source tree (e.g. `lua/falcon_measurement_lib/instrument_target.tl` or in `generated/teal`), the generator will prefer those canonical Teal modules. Otherwise minimal record stubs are emitted, but note: for best LSP experience add runtime Teal definitions for shared types like `InstrumentTarget` and `RuntimeContext` (see `runtime_context.tl` in the repo).

## Go generation: new behaviors

The Go generator was updated to produce matching Go types for request inputs and response outputs (and to map schema `$ref` to Go types):

- `$ref` mapping: JSON Schema `$ref` entries (e.g. `#/definitions/InstrumentTarget`) are now emitted as Go types with the referenced name (`InstrumentTarget`) rather than `interface{}`.

- No `omitempty`: JSON struct tags no longer include `omitempty`. Fields are emitted as:

  ```go
  FieldName Type `json:"fieldName"`
  ```

  This ensures zero/empty values are serialized (required by your runtime).

- MeasurementResponse concrete types: for each primitive `x-valueType` used by scripts, the generator emits a concrete `MeasurementResponseX` struct:
  - `MeasurementResponseNumber` (Value float64)
  - `MeasurementResponseString` (Value string)
  - `MeasurementResponseBoolean` (Value bool)
  - `MeasurementResponseBuffer` (Value []byte)

- Per-script types:
  For each script the generator now emits:
  - `<ScriptName>Request` — Go struct representing the inputs (schema.properties)
  - `<ScriptName>Response` — type alias or struct representing outputs:
    - Single measurement → alias to the concrete `MeasurementResponseX`
    - Array measurement → `[]MeasurementResponseX`
    - No returns -> empty struct
  - `<ScriptName>Spec` — wrapper struct:

    ```go
    type GetVoltageSpec struct {
      Input GetVoltageRequest `json:"input"`
      Output GetVoltageResponse `json:"output"`
    }
    ```

- Helpers:
  - `InstrumentTarget.Serialize()` helper is still generated when `InstrumentTarget` is present.

### Example Go output (illustrative)

Given a script `Set_Sample_Rate` with a `$ref`-typed `getter` and a `sampleRate` number, and no returns:

```go
type Set_Sample_RateRequest struct {
    Getter InstrumentTarget `json:"getter"` // The instrument (and channel) to collect the sample rate from.
    SampleRate float64      `json:"sampleRate"` // The sample rate to set in units of samples/msec.
}

type Set_Sample_RateResponse struct {} // no returns

type Set_Sample_RateSpec struct {
    Input  Set_Sample_RateRequest  `json:"input"`
    Output Set_Sample_RateResponse `json:"output"`
}
```

If a script returns a `MeasurementResponse<number>` (single), the generator will also emit `MeasurementResponseNumber` and set `<ScriptName>Response` to that type.

## Editor setup

- For Lua/Emmy users (sumneko / lua-language-server):
  - Place `generated/emmy/` in an indexed path (project root or workspace) so the LSP can pick up `---@class` and `---@field` annotations.

- For Teal users:
  - Install `tl` and `teal-language-server`.
  - Ensure `runtime_context.tl` and any runtime `.tl` definitions for shared types are available to the LSP.
  - Run:

    ```
    tl check generated/teal/scripts/*.tl
    ```

    to validate generated Teal in CI or locally.

## Adding or fixing `returns` in schemas

- Use the strict `allOf + x-valueType` pattern described above. The generator will fail when `returns` exists but does not match the preferred pattern.

- There is a helper `generator/patch_schemas_add_returns.lua` in the repo that can add conservative `returns` blocks to scripts that lack them; however, if you use the helper you must verify/adjust its output so that `allOf + x-valueType` is used (the helper is provided for convenience but you may prefer to author `returns` manually to match the strict pattern).

## CI recommendations

- Generation failure should fail the CI job. Because the generator is strict about `returns` shapes, run the generator and fail fast if any schema needs updating:

  ```
  lua generator/gen_from_schemas.lua ./schemas/lib ./schemas/scripts ./lua ./generated
  ```

- After generation, run Teal check (if Teal emitted):

  ```
  tl check generated/teal/scripts/*.tl
  ```

- Optionally run `go vet` / `go test` on generated Go packages if you import them in your toolchain.

## Examples

- Array of MeasurementResponse (preferred pattern):

  ```json
  {
    "title": "Get_All_Voltages",
    "type": "object",
    "properties": {
      "getters": {
        "type": "array",
        "items": { "$ref": "../lib/instrument_target.json#/definitions/InstrumentTarget" }
      }
    },
    "returns": {
      "type": "array",
      "items": {
        "allOf": [
          { "$ref": "../lib/measurement_response.json#/definitions/MeasurementResponse" },
          { "x-valueType": "number" }
        ]
      }
    }
  }
  ```

  - Teal: `MeasurementResponses<number>`
  - Go: `[]MeasurementResponseNumber` + `Get_All_VoltagesRequest` + `Get_All_VoltagesResponse` + `Get_All_VoltagesSpec`

- Single MeasurementResponse (preferred pattern):

  ```json
  {
    "title": "Get_Number_Of_Samples",
    "type": "object",
    "properties": {
      "getter": { "$ref": "../lib/instrument_target.json#/definitions/InstrumentTarget" }
    },
    "returns": {
      "allOf": [
        { "$ref": "../lib/measurement_response.json#/definitions/MeasurementResponse" },
        { "x-valueType": "number" }
      ]
    }
  }
  ```

  - Teal: `MeasurementResponse<number>`
  - Go: `MeasurementResponseNumber` + `Get_Number_Of_SamplesRequest` + `Get_Number_Of_SamplesResponse` + `Get_Number_Of_SamplesSpec`

## Support and feedback

If you hit issues integrating the stricter `returns` conventions or have opinions about key types (string vs record) for return maps, open an issue or a PR — we will iterate. The strict pattern is intended to keep Teal + Go + runtime behavior consistent and type-safe across the toolchain.
