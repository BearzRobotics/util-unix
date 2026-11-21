# Cutting a release

Releases are built by `.github/workflows/release.yml` when a tag `v*` is pushed. The
workflow installs Zig 0.17.1 (pinned), calls `scripts/package.sh` for each target, writes
`SHA256SUMS`, takes the release notes from the `CHANGELOG.md` section of the version and
creates the GitHub release. Running the workflow by hand (workflow_dispatch) is a dry run:
it builds the archives as workflow artifacts and publishes nothing.

## Assets

| File | Target |
|---|---|
| `util-unix-VERSION-linux-x86_64.tar.gz` | x86_64-linux-musl (static) |
| `util-unix-VERSION-linux-aarch64.tar.gz` | aarch64-linux-musl (static) |
| `SHA256SUMS` | checksums of the above |

Each archive holds one directory with `bin/` (all standalone commands and the `util-unix`
multicall binary), `share/man/man1/` (the manual pages), `LICENSE`, `README.md` and
`CHANGELOG.md`. Built with `-Doptimize=ReleaseSafe -Dstrip=true`.

Other targets (macOS, other architectures) build from source; no prebuilt macOS binaries are published
because no maintainer owns a Mac, and they will be offered once a volunteer with a Mac steps up to
test and maintain that platform. `ci.yml` cross-compiles Linux and macOS (compile check only; nothing is run).

## Checklist

1. `main` is green in CI (`zig build`, `zig build test`, all three modes, all cross targets).
2. Run the full differential suites locally (`sh test/run_all_tests.sh` after
   `zig build -Doptimize=ReleaseSafe`). Do not run the `sync` global-flush cases.
3. Run the QEMU guest tests (`sh test/vm/run.sh`) and the `sh` corpora (`test/test_sh_corpora.sh`).
4. Bump the version in `build.zig.zon` (the single source; `--version` reads it); update
   the version in the manual pages (`This manual describes util-unix X.Y.Z.`).
5. Add a `## X.Y.Z` section to `CHANGELOG.md`; check it renders as release notes:
   `scripts/release-notes.sh X.Y.Z`.
6. Update README, and the docs if platform status changed.
7. Test packaging locally: `scripts/package.sh x86_64-linux-musl linux-x86_64 dist` (runs the
   binary), then unpack and try it. Other archive: `scripts/package.sh aarch64-linux-musl linux-aarch64 dist`
   (built, not run).
8. Commit, merge to `main`, then tag and push: `git tag -a vX.Y.Z -m "util-unix X.Y.Z"` and
   `git push origin main vX.Y.Z`. The workflow refuses a tag that differs from `build.zig.zon`.
9. Watch the workflow; check the release page, `SHA256SUMS`, and download one Linux archive
   and run `bin/util-unix uname --version`.
10. Optional dry run before tagging: Actions, release, "Run workflow".
