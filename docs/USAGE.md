# Usage and Deployment

Install runtime Lua library (server):

1. Download `lua-lib-<VERSION>.tar.gz` from the Release assets.
2. Extract to desired location, e.g. `/opt/falcon-measurement-lib/v1.0.0/`.
   - The library root should contain `falcon_measurement_lib/` directory (module files).
3. Set environment variable for instrument-server:
   - `export INSTRUMENT_SCRIPT_SERVER_OPT_LUA_LIB=/opt/falcon-measurement-lib/v1.0.0`
4. Start the instrument-server; it will add this path to `package.path` and `require` modules via that namespace.

Use generated Go types (compiler):

1. Download `go-types-<VERSION>.tar.gz` from the Release assets.
2. Extract `generated/*.go` into your compiler project (or publish as a Go module).
3. Use the generated structs to populate the context and call `.ToMap()` to produce `context_spec`.

Editor support (LSP):

1. Download `emmy-headers-<VERSION>.tar.gz`.
2. Place the `.lua` files into a location your Lua LSP (sumneko/lua-language-server) indexes (e.g., project root or workspace folder).
3. Authors will get type hints and method signatures while editing measurement scripts.

Contributing new schemas and helpers:

- Add reusable types to `schemas/lib/` (and implement runtime helpers under `lua/falcon_measurement_lib/` if methods are required).
- Add script context schemas to `schemas/scripts/`.
- Run `make generate` locally to produce generated artifacts in `generated/`.
- Run `make package-all` to create the release tarballs for local testing.
