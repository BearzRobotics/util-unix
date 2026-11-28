#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# getent: differential tests against glibc's getent. References: getent(1);
# the file formats in section 5 of the man pages. Our getent reads the files
# only (decision 0004), so keys are drawn from the files themselves; entries
# glibc finds through NSS sources other than files (systemd-userdb, DNS, ...)
# are outside what can match and are not tested.
UTIL="getent"
REF_PATTERN="GLIBC"
. "$(dirname "$0")/testlib.sh"
export LC_ALL=C

# Names and numbers that occur in a file; skips comments and blank lines.
col() { # col FILE N: Nth whitespace-separated field of data lines
    awk -v n="$2" '!/^[ \t]*(#|$)/ { print $n }' "$1" 2>/dev/null
}

printf "\n[ passwd / group (keys from the files) ]\n"
run_cmp "passwd root"                    passwd root
run_cmp "passwd by uid 0"                passwd 0
run_cmp "passwd several keys"            passwd root daemon bin
run_cmp "passwd missing among found"     passwd root nosuchuser daemon
run_cmp "passwd all system names"        passwd $(awk -F: '$3 < 1000 {print $1}' /etc/passwd)
run_cmp "passwd all system uids"         passwd $(awk -F: '$3 < 1000 {print $3}' /etc/passwd)
run_cmp "passwd numeric not found"       passwd 54321
run_cmp "passwd key with leading zero"   passwd 00
run_cmp "group all system names"         group $(awk -F: '$3 < 1000 {print $1}' /etc/group)
run_cmp "group all system gids"          group $(awk -F: '$3 < 1000 {print $3}' /etc/group)
run_cmp "group missing"                  group nosuchgroup
# a key that only starts like a number is a name: it must not mean uid 0
for k in 0abc 0x0 1000x " 0" "+0" "  00" "0 " 0.0 + 18446744073709551616; do
    run_cmp "passwd key '$k'"            passwd "$k"
    run_cmp "group key '$k'"             group "$k"
done
run_cmp "services keys that only start like a port" services 22abc 22abc/tcp 80x
# a port or id too large for its type names nothing (and once crashed services)
run_cmp "services port too large"        services 4294967296 99999999999/tcp 18446744073709551616
# 2^32 must not wrap to 0 (glibc's does, and prints root: not compared)
if [ -z "$(ours passwd 4294967296)" ]; then PASS=$((PASS + 1)); echo "PASS passwd 4294967296 is not root"
else FAIL=$((FAIL + 1)); echo "FAIL passwd 4294967296 is not root"; fi
run_cmp "initgroups for current user"    initgroups "$(id -un)"
run_cmp "initgroups unknown user"        initgroups nosuchuser
run_cmp "initgroups enumeration"         initgroups
run_cmp "shadow unknown name"            shadow nosuchuser
run_cmp "gshadow unknown name"           gshadow nosuchgroup
run_cmp "netgroup lookup"                netgroup nosuchgroup
run_cmp "netgroup enumeration"           netgroup

printf "\n[ services ]\n"
run_cmp "services enumeration"           services
run_cmp "services every name"            services $(col /etc/services 1 | sort -u)
run_cmp "services every port/proto"      services $(col /etc/services 2 | sort -u)
run_cmp "services every port"            services $(col /etc/services 2 | cut -d/ -f1 | sort -un)
run_cmp "services name/tcp"              services http/tcp domain/tcp domain/udp
run_cmp "services name wrong protocol"   services http/udp
run_cmp "services unknown"               services nosuchservice 99999/tcp
run_cmp "services aliases"               services www sink null

printf "\n[ protocols ]\n"
run_cmp "protocols enumeration"          protocols
run_cmp "protocols every name"           protocols $(col /etc/protocols 1 | sort -u)
run_cmp "protocols every number"         protocols $(col /etc/protocols 2 | sort -un)
run_cmp "protocols every alias"          protocols $(col /etc/protocols 3 | sort -u)
run_cmp "protocols unknown"              protocols nosuchproto 999

printf "\n[ rpc ]\n"
run_cmp "rpc enumeration"                rpc
run_cmp "rpc every name"                 rpc $(col /etc/rpc 1 | sort -u)
run_cmp "rpc every number"               rpc $(col /etc/rpc 2 | sort -un)
run_cmp "rpc aliases"                    rpc portmap rpcbind
run_cmp "rpc unknown"                    rpc nosuchrpc 1

printf "\n[ networks ]\n"
run_cmp "networks enumeration"           networks
run_cmp "networks every name"            networks $(col /etc/networks 1 | sort -u)
run_cmp "networks by address"            networks $(col /etc/networks 2 | sort -u)
run_cmp "networks unknown"               networks nosuchnet

printf "\n[ hosts: entries that the files answer unambiguously ]\n"
run_cmp "hosts by address 127.0.0.1"     hosts 127.0.0.1
# GNU answers ::1 from an NSS module (nss-myhostname) when /etc/hosts has no entry; this
# getent reads files only (decision 0004), so compare only when the file has the line.
if grep -q '^::1[[:space:]]' /etc/hosts; then run_cmp "hosts by address ::1"           hosts ::1; fi
# (without the name in /etc/hosts both print nothing, and nothing is looked up)
if grep -qw ip6-localhost /etc/hosts; then run_cmp "hosts alias lookup" hosts ip6-localhost
else skip_test "hosts alias lookup (/etc/hosts has no ip6-localhost)"; fi
run_cmp "hosts unknown name"             hosts nosuch.invalid
run_cmp "ahostsv4 localhost"             ahostsv4 localhost
run_cmp "ahostsv4 literal"               ahostsv4 127.0.0.1
# glibc asks with AI_ADDRCONFIG, so a host whose only IPv6 address is on lo (a
# container, usually) gets no answer from it; ours does not look at that.
if grep -qv ' lo$' /proc/net/if_inet6 2>/dev/null; then
    run_cmp "ahostsv6 localhost (mapped)"    ahostsv6 localhost
else
    skip_test "ahostsv6 localhost (mapped) (no IPv6 address outside loopback)"
fi

printf "\n[ Options and errors ]\n"
run_cmp "no arguments"
run_cmp "unknown database"               bogus x
run_cmp "unknown option"                 -x passwd
run_cmp "unknown long option"            --bogus passwd
run_cmp "-s without argument"            -s
run_cmp "-s files"                       -s files passwd root
run_cmp "--service=files"                --service=files group root
run_cmp "-s passwd:files"                -s passwd:files passwd root
run_cmp "-s unknown database name"       -s files:foo passwd root
run_cmp "-s dns finds nothing"           -s dns services http
run_cmp "--serv abbreviation"            --serv=files passwd root
run_cmp "-A and -i accepted"             -A -i passwd root
run_cmp "--no-idn / --no-addrconfig"     --no-idn --no-addrconfig passwd root
run_cmp "options after operands"         passwd root -i
run_cmp "-- ends options"                -- passwd root
run_cmp "--usage"                        --usage
run_cmp "--no-idn=x takes no argument"   --no-idn=x passwd root

for o in --help=1 --usage=1 --version=1; do
    if ours "$o" > /dev/null 2>&1; then rc=0; else rc=$?; fi
    if [ "$rc" = 64 ]; then PASS=$((PASS + 1)); echo "PASS no value for $o"
    else FAIL=$((FAIL + 1)); echo "FAIL no value for $o (exit $rc)"; fi
done
# a made-up /etc/aliases, compared inside a private /etc. (No doubled commas:
# glibc never returns from those.)
if command -v bwrap > /dev/null 2>&1 && bwrap --ro-bind / / true 2> /dev/null && ldd --version 2>&1 | grep -qi 'glibc\|gnu'; then
    al="$(mktemp -d)"; echo 'aliases: files' > "$al/nsswitch.conf"
    printf '# c\n  indented, two words\nthree\n\n:include:/nonexistent\n' > "$al/list"; : > "$al/empty"
    printf '%s\n' '# comment' 'postmaster: root' 'team: alice,' '  bob,' '	carol' 'q: "|/bin/prog a b", other' \
        "inc: :include:$al/list, tail" 'miss: :include:/nonexistent' 'after: x # y' 'continued: a' '# between' '  b' \
        'blank: a' '' '  b' 'empty:' '  late' 'nothing:' 'z:  a b , c  ' 'UPPER: z' 'nocolon' \
        'a-very-long-alias-name-beyond-sixteen: v' "none: :include:$al/empty, y" > "$al/aliases"
    in_al() { timeout -s KILL 10 bwrap --die-with-parent --ro-bind / / --tmpfs /etc --ro-bind "$al/aliases" /etc/aliases \
        --ro-bind "$al/nsswitch.conf" /etc/nsswitch.conf "$@" 2>&1; echo "rc=$?"; }
    for k in "" team q inc miss after continued blank empty nothing z upper a-very-long-alias-name-beyond-sixteen none nosuch; do
        x="$(in_al /usr/bin/getent aliases ${k:+"$k"})"; y="$(in_al "$BIN_DIR/getent" aliases ${k:+"$k"})"
        if [ "$x" = "$y" ]; then PASS=$((PASS + 1)); echo "PASS aliases '$k'"
        else FAIL=$((FAIL + 1)); echo "FAIL aliases '$k'"; echo "     GNU : $x"; echo "     OURS: $y"; fi
    done
else
    skip_test "aliases comparison needs bwrap and glibc"
fi

print_summary
[ "$FAIL" -eq 0 ]
