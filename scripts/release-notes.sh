#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Print the CHANGELOG.md section of one version (the lines after "## VERSION" up to the
# next "## " heading), for use as release notes.
#
#   scripts/release-notes.sh [VERSION]    default: the version in build.zig.zon
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version=${1:-$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)}
version=${version#v}
awk -v v="$version" '
    $0 == "## " v || index($0, "## " v " ") == 1 { on = 1; next }
    on && /^## / { exit }
    on { print }
' CHANGELOG.md > "${TMPDIR:-/tmp}/rn.$$"
if ! grep -q '[^[:space:]]' "${TMPDIR:-/tmp}/rn.$$"; then
    rm -f "${TMPDIR:-/tmp}/rn.$$"
    echo "CHANGELOG.md has no '## $version' section" >&2
    exit 1
fi
cat "${TMPDIR:-/tmp}/rn.$$"
rm -f "${TMPDIR:-/tmp}/rn.$$"
