#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# chcon: differential tests against GNU chcon 9.7. The host kernel has no SELinux,
# where `security.selinux` is an ordinary extended attribute that an unprivileged
# user may set on tmpfs and ext4; so contexts are plain strings and the result is
# compared by reading the attribute of every file afterwards. Skipped when the
# scratch file system refuses security.* attributes.
UTIL="chcon"
export LC_ALL=C
. "$(dirname "$0")/testlib.sh"

if ! command -v python3 >/dev/null 2>&1; then echo "SKIP chcon (python3 needed)"; exit 0; fi
BASE="$(mktemp -d)"; trap 'rm -rf "$BASE"' EXIT
touch "$BASE/probe"
if ! /usr/bin/chcon a:b:c:d "$BASE/probe" 2>/dev/null; then
    echo "SKIP chcon (this file system does not accept security.* attributes)"; exit 0
fi

# Attribute dump: path, kind, context (NUL shown as <NUL>), for the whole tree.
dump() { python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
for dirpath, dirs, files in os.walk(root):
    for n in sorted(dirs + files):
        p = os.path.join(dirpath, n)
        try: v = os.getxattr(p, "security.selinux", follow_symlinks=False).decode().replace("\0", "<NUL>")
        except OSError as e: v = "ERR%d" % e.errno
        print(os.path.relpath(p, root), "L" if os.path.islink(p) else "-", v)
PY
}

SETUP='mkdir -p d/sub e && touch d/f d/sub/g e/h plain && ln -s d/f link && ln -s nowhere dangling && ln -s d dlink &&
       for x in d/f d/sub/g d/sub d e/h; do /usr/bin/chcon -h u:r:t:s0 $x; done'
ctree() { # description, args...
    description="$1"; shift
    rm -rf "$BASE/g" "$BASE/o"; mkdir -p "$BASE/g" "$BASE/o"
    for x in g o; do (cd "$BASE/$x" && eval "$SETUP"); done
    (cd "$BASE/g" && /usr/bin/chcon "$@" > "$BASE/g.out" 2> "$BASE/g.err"; echo $? > "$BASE/g.rc")
    if [ -n "${OURS_MULTICALL:-}" ]; then (cd "$BASE/o" && "$BIN_DIR/util-unix" chcon "$@" > "$BASE/o.out" 2> "$BASE/o.err"; echo $? > "$BASE/o.rc")
    else (cd "$BASE/o" && "$BIN_DIR/chcon" "$@" > "$BASE/o.out" 2> "$BASE/o.err"; echo $? > "$BASE/o.rc"); fi
    norm_err < "$BASE/g.err" > "$BASE/g.err2"; norm_err < "$BASE/o.err" > "$BASE/o.err2"
    dump "$BASE/g" > "$BASE/g.tree"; dump "$BASE/o" > "$BASE/o.tree"
    if cmp -s "$BASE/g.out" "$BASE/o.out" && cmp -s "$BASE/g.err2" "$BASE/o.err2" && cmp -s "$BASE/g.rc" "$BASE/o.rc" && cmp -s "$BASE/g.tree" "$BASE/o.tree"; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU  rc=%s out=%s err=%s\n     OURS rc=%s out=%s err=%s\n" "$description" \
            "$(cat "$BASE/g.rc")" "$(cat -A "$BASE/g.out")" "$(cat -A "$BASE/g.err2")" "$(cat "$BASE/o.rc")" "$(cat -A "$BASE/o.out")" "$(cat -A "$BASE/o.err2")"
        diff "$BASE/g.tree" "$BASE/o.tree" | head -8
    fi
}

ctree "full context"                 a:b:c:d d/f plain
ctree "full context -v"              -v a:b:c:d d/f plain
ctree "full context on a link follows it"        x:y:z:w link
ctree "full context -h on a link"    -h x:y:z:w link
ctree "-h dangling"                  -h -v x:y:z:w dangling
ctree "dangling without -h"          -v x:y:z:w dangling
ctree "several files, one missing"   -v q:q:q:q d/f nosuch plain
ctree "recursive"                    -R -v a:b:c:d d
ctree "recursive, two operands"      -R a:b:c:d d e
ctree "recursive -h"                 -R -h a:b:c:d d link
ctree "-R -H on a link to a directory" -R -H -v a:b:c:d dlink
ctree "-R -L on a link to a directory" -R -L -v a:b:c:d dlink
ctree "-R -P on a link to a directory" -R -P -v a:b:c:d dlink
ctree "-R --dereference"             -R --dereference a:b:c:d d
ctree "-R --dereference -L"          -R --dereference -L a:b:c:d dlink
ctree "-R --preserve-root /"         -R --preserve-root a:b:c:d /
ctree "-R --no-preserve-root nofile" -R --no-preserve-root a:b:c:d nofile
ctree "type only"                    -t newtype d/f
ctree "type, -v"                     -v -t newtype d/f
ctree "user role range"              -u nu -r nr -l s0:c1.c9 d/f
ctree "user only, two files"         -u nu d/f d/sub/g
ctree "attached option values"       -tnewt -unewu d/f
ctree "long options"                 --type=newt --user=newu --role=newr --range=s1 d/f
ctree "long options with separate values" --type newt --user newu d/f
ctree "range with colons"            -l s0:c0.c1023 d/f
ctree "empty range removes it"       -l '' d/f
ctree "partial on unlabeled file"    -t x plain
ctree "partial -v on unlabeled file" -v -t x plain
ctree "partial on missing file"      -t x nofile
ctree "partial recursive"            -R -t newt d
ctree "partial recursive, some unlabeled" -R -t newt d e plain
ctree "bad component"                -t 'a:b' d/f
ctree "bad user component"           -u 'a:b' d/f
ctree "bad existing context"         -t x d/f plain
ctree "--reference"                  --reference=d/f plain
ctree "--reference -v"               -v --reference=d/f plain
ctree "--reference missing"          --reference=nofile plain
ctree "--reference unlabeled"        --reference=plain d/f
ctree "--reference recursive"        -R --reference=d/f e
ctree "full context 2 components"    a:b d/f
ctree "empty context"                '' d/f
ctree "-- separates operands"        -- a:b:c:d d/f
ctree "no arguments"
ctree "context only"                 a:b:c:d
ctree "components only"              -t x
ctree "--reference only"             --reference=d/f
ctree "-t without value"             -t
ctree "-x"                           -x
ctree "--bogus"                      --bogus
ctree "--type without value"         --type
ctree "--verbose=1"                  --verbose=1 a:b:c:d d/f
ctree "--rec abbreviation"           --rec a:b:c:d d
ctree "--re (ambiguous)"             --re a:b:c:d d
g="$(/usr/bin/chcon --help | sed 's#/usr/bin/chcon#chcon#g' | sed '/^GNU coreutils online help/,$d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
o="$("$BIN_DIR/chcon" --help)"
if [ "$g" = "$o" ]; then PASS=$((PASS + 1)); echo "PASS --help"; else FAIL=$((FAIL + 1)); echo "FAIL --help"; fi
print_summary
