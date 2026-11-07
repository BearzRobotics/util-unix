#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the versioned source tarball for a release.
#
#   scripts/release.sh   check consistency, write dist/util-unix-VERSION.tar.gz,
#                        print its sha256 and the Zig package hash
#
# The version comes from build.zig.zon. The tarball is made with `git archive`
# from HEAD, so it contains exactly what is committed (tests and docs
# included), and it is reproducible for a given commit: `gzip -n` leaves out
# the file name and time. util-unix has no dependencies, so this one tarball
# is also what a vendoring packager (for example dkbuilder's %zig_build) needs.
# It does not need the tag to exist yet.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)"
[ -n "$version" ] || { echo "cannot read the version from build.zig.zon" >&2; exit 1; }

fail=0
grep -q "^## $version\$" CHANGELOG.md || { echo "CHANGELOG.md has no '## $version' section" >&2; fail=1; }
for m in docs/manpages/*.md; do
    [ "$(basename "$m")" = template.md ] && continue
    grep -q "Version $version |" "$m" || { echo "$m does not say 'Version $version'" >&2; fail=1; }
done
[ -f LICENSE ] || { echo "LICENSE is missing" >&2; fail=1; }
[ -z "$(git status --porcelain)" ] || { echo "the working tree is not clean; commit first" >&2; fail=1; }
[ $fail = 0 ] || exit 1

mkdir -p dist
out="dist/util-unix-$version.tar.gz"
git archive --format=tar --prefix="util-unix-$version/" HEAD | gzip -n -9 > "$out"
echo "wrote $out ($(du -h "$out" | cut -f1)) from $(git rev-parse --short HEAD)"
sha256sum "$out"
echo "zig hash:"
zig fetch "$out"
