# Instructions for coding agents

This is a fork of [MicroZig](https://github.com/ZigEmbeddedGroup/microzig) that welcomes
LLM-assisted contributions. The quality bar is the same for everyone.

1. **Read [`NO_SLOP.md`](NO_SLOP.md) before writing or reviewing code.** It is the review
   standard for every change.
2. **Read [`ARCHITECTURE.md`](ARCHITECTURE.md)** for the codemap and the architectural invariants:
   drivers never import port code, core is port-agnostic, register definitions are generated.
3. **Never edit generated register code or vendored SVD/ATDF files.** Add a patch in the port's
   `patches/` directory.
4. **Naming:** snake_case functions, PascalCase types. Run `zig fmt` before committing.
   CI fails a PR that touches a file with an unused import
   ([zigimports](https://github.com/mattnite/zigimports): `zigimports --fix <file>`), and
   annotates naming suggestions from `tools/linter` as warnings.
5. **Toolchain:** Zig version is pinned in `.tool-versions` and `build.zig.zon`
   (`minimum_zig_version`).
6. **Testing:** run `zig build test` in the directory you changed (`drivers/`, `tools/regz`,
   `port/<vendor>/<family>`, …) and `zig build -Doptimize=ReleaseSmall` at the root to build the
   examples. CI only builds firmware; it cannot run it. In a PR, state which evidence you have:
   built, unit-tested, or ran on hardware (name the board).
7. **Hardware claims cite the datasheet** (document and section), never memory.
