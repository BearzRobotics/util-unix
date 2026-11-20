#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# fetch-sh-corpora.sh - download the third-party POSIX shell test corpora that
# test/test_sh_corpora.sh runs `sh` against. Nothing is committed to this
# repository: the files are fetched at pinned commits into
#   ${SH_CORPORA_DIR:-$HOME/.cache/util-unix/sh-corpora}/{yash,freebsd,oils}
#
#   yash     https://github.com/magicant/yash          tests/*-p.tst (POSIX conformance tests) and the runner  (GPL-2.0-or-later)
#   freebsd  https://github.com/freebsd/freebsd-src    bin/sh/tests (every case exits 0 on success)           (BSD-2-Clause)
#   oils     https://github.com/oils-for-unix/oils     spec/*.test.sh (per-shell expected annotations)         (Apache-2.0)
#
# The pinned commits (update them here, then re-run; the record is also written
# to PINS next to the corpora):
YASH_REPO=https://github.com/magicant/yash.git
YASH_COMMIT=f1f1e1cbe64f76ceaf172f2689d72247f5111b12
FREEBSD_REPO=https://github.com/freebsd/freebsd-src.git
FREEBSD_COMMIT=90bc40e26c610b68595427e736bca5215ebe5c57
OILS_REPO=https://github.com/oils-for-unix/oils.git
OILS_COMMIT=d114978ca467143f171a835cbcbe8ab6ccc009a7
#
# Only the test directories are checked out (partial clone + sparse checkout of
# the pinned commit); git hooks are disabled. Nothing from the downloaded trees
# is ever executed by this script: test_sh_corpora.sh feeds the files to the
# shell under test through its own adapters.
#
#   tools/fetch-sh-corpora.sh            fetch what is missing
#   tools/fetch-sh-corpora.sh --force    re-fetch everything
set -eu

DEST="${SH_CORPORA_DIR:-${HOME:-/tmp}/.cache/util-unix/sh-corpora}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

fetch() {
    name="$1"; repo="$2"; commit="$3"; shift 3
    dir="$DEST/$name"
    if [ "$FORCE" = 0 ] && [ -f "$dir/.commit" ] && [ "$(cat "$dir/.commit")" = "$commit" ]; then
        echo "$name: already at $commit"
        return 0
    fi
    echo "$name: fetching $commit"
    rm -rf "$dir.tmp"
    mkdir -p "$dir.tmp"
    (
        cd "$dir.tmp"
        git init -q .
        git config core.hooksPath /dev/null
        git config advice.detachedHead false
        git remote add origin "$repo"
        git sparse-checkout init --cone
        git sparse-checkout set "$@"
        git fetch -q --depth 1 --filter=blob:none origin "$commit"
        git checkout -q FETCH_HEAD
    )
    echo "$commit" > "$dir.tmp/.commit"
    rm -rf "$dir"
    mv "$dir.tmp" "$dir"
}

mkdir -p "$DEST"
fetch yash "$YASH_REPO" "$YASH_COMMIT" tests
fetch freebsd "$FREEBSD_REPO" "$FREEBSD_COMMIT" bin/sh/tests
fetch oils "$OILS_REPO" "$OILS_COMMIT" spec
{
    echo "yash    $YASH_REPO $YASH_COMMIT"
    echo "freebsd $FREEBSD_REPO $FREEBSD_COMMIT"
    echo "oils    $OILS_REPO $OILS_COMMIT"
} > "$DEST/PINS"
echo "corpora in $DEST"
