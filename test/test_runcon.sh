#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# runcon: differential tests against GNU runcon 9.7 on a kernel without SELinux
# (checked and skipped otherwise). What can be compared there is the argument
# handling, printing the current context, and the refusal to run. A transition
# under a real policy is not covered: see docs/compatibility/runcon.md.
UTIL="runcon"
export LC_ALL=C
. "$(dirname "$0")/testlib.sh"

if grep -q '^[^ ]* [^ ]* selinuxfs ' /proc/mounts 2>/dev/null; then
    skip_test "runcon (this host has SELinux mounted; the no-SELinux comparisons do not apply)"; print_summary; exit 0
fi

# GNU prints the path it was run by in "may be used only on a SELinux kernel".
rc_cmp() { # description, args...
    description="$1"; shift
    LC_ALL=C gnu "$@" < /dev/null > "$TMPDIR_CMP.go" 2> "$TMPDIR_CMP.ge"; gx=$?
    ours "$@" < /dev/null > "$TMPDIR_CMP.oo" 2> "$TMPDIR_CMP.oe"; ox=$?
    sed -e "s#^[^ ]*/\\([a-z0-9]*\\): #\\1: #" -e "s#Try '[^']*'#Try 'PROG'#" -e 's#/usr/bin/runcon may be#runcon may be#' "$TMPDIR_CMP.ge" > "$TMPDIR_CMP.ge2"
    sed -e "s#^[^ ]*/\\([a-z0-9]*\\): #\\1: #" -e "s#Try '[^']*'#Try 'PROG'#" "$TMPDIR_CMP.oe" > "$TMPDIR_CMP.oe2"
    if cmp -s "$TMPDIR_CMP.go" "$TMPDIR_CMP.oo" && cmp -s "$TMPDIR_CMP.ge2" "$TMPDIR_CMP.oe2" && [ "$gx" = "$ox" ]; then
        PASS=$((PASS + 1)); printf "PASS %s\n" "$description"
    else
        FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU  (rc=%s) out: %s err: %s\n     OURS (rc=%s) out: %s err: %s\n" "$description" \
            "$gx" "$(cat -A "$TMPDIR_CMP.go")" "$(cat -A "$TMPDIR_CMP.ge2")" "$ox" "$(cat -A "$TMPDIR_CMP.oo")" "$(cat -A "$TMPDIR_CMP.oe2")"
    fi
}

rc_cmp "current context"
rc_cmp "-c only"                 -c
rc_cmp "-t only"                 -t x
rc_cmp "-u -r -t -l only"        -u u -r r -t t -l s0
rc_cmp "context without command" ctx
rc_cmp "context and command"     ctx true
rc_cmp "-t and command"          -t foo true
rc_cmp "-u -r -t -l and command" -u u -r r -t t -l s0 true
rc_cmp "-c and command"          -c true
rc_cmp "-c -t and command"       -c -t x true
rc_cmp "--compute"               --compute true
rc_cmp "-- before context"       -- ctx true
rc_cmp "-- before command"       -t x -- true
rc_cmp "options after context are the command's" ctx -t x true
rc_cmp "two operands"            x y
rc_cmp "attached option values"  -tfoo -ubar true
rc_cmp "long options"            --type=a --user=b --role=c --range=d true
rc_cmp "long options, separate values" --type a --user b true
rc_cmp "abbreviations"           --ty x --us y true
rc_cmp "--co (abbreviation)"     --co
rc_cmp "-z"                      -z
rc_cmp "-t without value"        -t
rc_cmp "--bogus"                 --bogus
rc_cmp "--type without value"    --type
rc_cmp "--compute=1"             --compute=1 true
g="$(gnu --help | sed 's#/usr/bin/runcon#runcon#g' | sed '/^GNU coreutils online help/,$d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
o="$(ours --help)"
if [ "$g" = "$o" ]; then PASS=$((PASS + 1)); echo "PASS --help"; else FAIL=$((FAIL + 1)); echo "FAIL --help"; fi
print_summary
