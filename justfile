# uring: An io_uring completion loop for Zig: one ring, one tick, and a user_data type you define. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests")]
[group("test")]
test:
    zig build test --summary all

[doc("Run the benchmarks (testingx, ReleaseFast): the loop against the hand-written loop. `just bench -- --filter=Batch` picks a group")]
[group("test")]
bench *ARGS:
    zig build bench -- {{ ARGS }}

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src bench build.zig
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src bench build.zig
    nix fmt
    oxfmt README.md AGENTS.md .github
    just --fmt

[doc("Build the guide and the API reference into zig-out/site")]
[group("docs")]
doc: api
    baskingspot-docs build uring

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve uring

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title uring --repo-url https://github.com/baskingspot/uring --rev main --format json --out docs/data

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

[doc("Everything CI runs")]
[group("ci")]
ci: test lint doc
