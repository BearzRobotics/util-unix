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
run_cmp "hosts by address ::1"           hosts ::1
run_cmp "hosts alias lookup"             hosts ip6-localhost
run_cmp "hosts unknown name"             hosts nosuch.invalid
run_cmp "ahostsv4 localhost"             ahostsv4 localhost
run_cmp "ahostsv4 literal"               ahostsv4 127.0.0.1
run_cmp "ahostsv6 localhost (mapped)"    ahostsv6 localhost

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

print_summary
[ "$FAIL" -eq 0 ]
