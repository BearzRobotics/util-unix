#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Run the behavioural suites in a throwaway Ubuntu 26.04 container. The
# differential tests compare with the GNU tools of that release (gnu-coreutils
# 9.7, glibc 2.43); other distributions' builds differ in stty and uname output.
#
#   zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
#   docker run --rm --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
#       --security-opt systempaths=unconfined -v "$PWD:/src:ro" ubuntu:26.04 sh /src/scripts/ci-suites.sh
#
# It installs packages and creates a user, so it refuses to run outside a container.
set -eu
[ -f /.dockerenv ] || [ -f /run/.containerenv ] || { echo "ci-suites: run this inside a container (see the header)" >&2; exit 2; }
[ -x /src/zig-out/bin/sh ] || { echo "ci-suites: build first (zig-out/bin is empty)" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -qq -y --no-install-recommends bash bubblewrap busybox-static dash ncurses-base \
    procps python3 shellcheck strace util-linux >/dev/null
# 26.04 ships the Rust coreutils by default: swap in GNU, as testlib.sh requires
apt-get install -qq -y --no-install-recommends --allow-remove-essential \
    coreutils-from-gnu coreutils-from-uutils- >/dev/null

# test_getent.sh assumes a desktop's file, where only 127.0.0.1 is named
# "localhost". A container names ::1 so too, and `getent ahosts localhost`
# then differs from glibc's: a known getent difference this does not cover.
printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$(hostname)" > /etc/hosts

# The tests compare what an ordinary user may change, and need a second group.
useradd --create-home --groups users,staff tester
mkdir /work
cp -r /src/docs /src/src /src/test /src/tools /src/zig-out /work/
chown -R tester:tester /work

cd /work
exec su tester -c 'env -u NO_COLOR TERM=xterm LANG=C.UTF-8 UU_REQUIRE_SANDBOX=1 sh test/run_all_tests.sh'
