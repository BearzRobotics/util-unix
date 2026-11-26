#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Build and test on a real musl system, a throwaway Alpine container: the build
# and the unit tests run there natively, then the behavioural suites. Alpine's
# GNU coreutils (9.7 in 3.22) is the reference. Four commands have none here, so
# their suites are skipped (ci-suites.sh runs them): getent is glibc's, Alpine has
# no GNU groups or Debian hostname, and GNU who prints nothing on musl, which has
# no utmp.
#
# /zig must hold a Zig toolchain (the zig binary with its lib directory):
#   docker run --rm --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
#       --security-opt systempaths=unconfined -v "$PWD:/src:ro" \
#       -v "$(dirname "$(readlink -f "$(command -v zig)")"):/zig:ro" alpine:3.22 sh /src/scripts/ci-musl.sh
#
# It installs packages and creates a user, so it refuses to run outside a container.
set -eu
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || { echo "ci-musl: run this inside a container (see the header)" >&2; exit 2; }
[ -x /zig/zig ] || { echo "ci-musl: mount a Zig toolchain at /zig (see the header)" >&2; exit 2; }
ldd --version 2>&1 | grep -q musl || { echo "ci-musl: this is not a musl system" >&2; exit 2; }

apk add -q bash bubblewrap coreutils dash findutils ncurses-terminfo-base procps-ng python3 \
    shadow shellcheck strace util-linux util-linux-misc yash >/dev/null

# the tests take reference commands from /usr/bin
for u in bash busybox chcon chgrp chmod chown hostname id pinky runcon stty tty uname; do
    [ -x "/usr/bin/$u" ] || ln -s "$(command -v "$u")" "/usr/bin/$u"
done

# as in ci-suites.sh: only 127.0.0.1 is named "localhost"
printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$(hostname)" > /etc/hosts 2>/dev/null || true

getent group staff >/dev/null || groupadd staff
useradd --create-home --groups users,staff tester
mkdir /work
cp -r /src/build.zig /src/build.zig.zon /src/docs /src/src /src/test /src/tools /src/scripts /work/
chown -R tester:tester /work

cd /work
exec su tester -c '
set -eu
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache-global
echo "== native build and unit tests on Alpine $(cat /etc/alpine-release) (musl)"
/zig/zig build -Doptimize=ReleaseSafe
/zig/zig build test --summary all
env -u NO_COLOR TERM=xterm LANG=C.UTF-8 UU_REQUIRE_SANDBOX=1 UU_NO_REFERENCE="getent groups hostname who" \
    sh test/run_all_tests.sh'
