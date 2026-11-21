#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Build one release archive.
#
#   scripts/package.sh TARGET LABEL [OUTDIR]
#
#   TARGET  a Zig target triple: x86_64-linux-musl, aarch64-windows, aarch64-macos, ...
#   LABEL   the platform name used in the file name: linux-x86_64, windows-aarch64,
#           macos-x86_64-UNTESTED, ...
#   OUTDIR  where the archive is written (default: dist)
#
# Writes OUTDIR/NAME-VERSION-LABEL.tar.gz (OUTDIR/NAME-VERSION-LABEL.zip for Windows
# targets), where NAME and VERSION come from build.zig.zon. The archive holds one
# directory, NAME-VERSION-LABEL/, with
#   bin/              every standalone command plus the NAME multicall binary
#   share/man/man1/   the manual pages (Markdown, dkman layout; -Dman)
#   LICENSE README.md CHANGELOG.md
#
# Environment: OPTIMIZE (default ReleaseSafe), ZIG (default zig), SMOKE=0 to skip the
# run check. When TARGET can run on this machine the multicall binary is run
# (--version and a few commands) before the archive is written.
set -eu

[ $# -ge 2 ] || { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
target=$1
label=$2
root="$(cd "$(dirname "$0")/.." && pwd)"
outdir=${3:-dist}
case $outdir in /*) ;; *) outdir="$PWD/$outdir" ;; esac
zig=${ZIG:-zig}
optimize=${OPTIMIZE:-ReleaseSafe}

cd "$root"
name=$(sed -n 's/.*\.name = \.\([a-z_]*\),.*/\1/p' build.zig.zon | head -n1 | tr _ -)
version=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)
[ -n "$name" ] && [ -n "$version" ] || { echo "cannot read name/version from build.zig.zon" >&2; exit 1; }

base="$name-$version-$label"
work=$(mktemp -d "${TMPDIR:-/tmp}/package.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM
stage="$work/$base"
mkdir -p "$stage" "$outdir"

echo "building $base ($target, $optimize)"
"$zig" build -Dtarget="$target" -Doptimize="$optimize" -Dstrip=true -Dmode=all -Dman=true --prefix "$stage"

# Developer tools are not part of the release.
rm -f "$stage/bin/syntax-probe" "$stage/bin/syntax-probe.exe"
find "$stage" -name '*.pdb' -delete
for f in LICENSE README.md CHANGELOG.md; do [ -f "$f" ] && cp "$f" "$stage/$f"; done

case $target in
*windows*) exe=".exe" ;;
*) exe="" ;;
esac
[ -x "$stage/bin/$name$exe" ] || { echo "missing bin/$name$exe" >&2; exit 1; }
ls "$stage"/share/man/man1/*.1.md >/dev/null

# Run check, only where the binary can run here.
host="$(uname -s)-$(uname -m)"
runner=""
case "$target:$host" in
x86_64-linux*:Linux-x86_64 | aarch64-linux*:Linux-aarch64) runner="" ; can_run=1 ;;
x86_64-windows*:Linux-x86_64) command -v wine >/dev/null 2>&1 && { runner="wine"; can_run=1; } || can_run=0 ;;
*) can_run=0 ;;
esac
if [ "${SMOKE:-1}" = 1 ] && [ "$can_run" = 1 ]; then
    echo "run check: $runner $name$exe"
    mc="$stage/bin/$name$exe"
    case $name in
    util-unix) probe=uname; script='[ "$($runner "$mc" sh -c "echo hello")" = hello ]' ;;
    *) probe=echo; script='[ "$(printf "b\\na\\n" | $runner "$mc" sort | tr -d "\\r" | tr "\\n" " ")" = "a b " ]' ;;
    esac
    v=$($runner "$mc" $probe --version | tr -d "\r" | head -n1); echo "$v"
    case $v in "$probe ($name) $version"*) ;; *) echo "run check failed: version line" >&2; exit 1 ;; esac
    eval "$script" || { echo "run check failed: $probe" >&2; exit 1; }
else
    echo "run check skipped (cannot run $target on $host)"
fi

case $target in
*windows*)
    out="$outdir/$base.zip"
    rm -f "$out"
    (cd "$work" && find "$base" -type f | LC_ALL=C sort | zip -X -q -9 "$out" -@)
    ;;
*)
    out="$outdir/$base.tar.gz"
    (cd "$work" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - "$base") | gzip -n -9 > "$out"
    ;;
esac
echo "wrote $out ($(du -h "$out" | cut -f1))"
