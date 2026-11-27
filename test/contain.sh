#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# contain.sh - run a command so that a runaway in it cannot harm the caller.
#
#   sh test/contain.sh COMMAND [ARG...]
#
# The suites run shells on purpose-built hostile input. A bug can make one
# allocate without end; the kernel's OOM killer then fires, and systemd stops
# the whole unit the process was in, which is the caller's terminal or session.
# So the command gets a systemd scope of its own with a hard memory limit and
# no swap: only the process that ran away is killed (OOMPolicy=continue), its
# case fails and the rest of the run goes on. It is also marked as the first
# choice of the OOM killer.
#
#   TEST_MEM_MAX=4G   memory limit of the whole run
#
# Without a systemd user session it refuses to run, except where something
# else bounds the damage: in a container (limit it with docker run --memory),
# on a CI runner (CI set), or when TEST_UNCONTAINED=1 asks for it.
#
# TEST_CONTAINED names the cgroup of the scope made here, so that a nested call
# does not make another one. A value that names any other cgroup (inherited from
# somewhere else) is not believed.
here="cg:$(cat /proc/self/cgroup 2>/dev/null)"
if [ "${TEST_CONTAINED:-}" = "$here" ]; then
    exec "$@"
fi
# raising the score needs no privilege
{ echo 500 > /proc/self/oom_score_adj; } 2>/dev/null
if [ -z "${TEST_CONTAIN_INNER:-}" ] && command -v systemd-run > /dev/null 2>&1 \
    && systemd-run --user --scope --quiet true > /dev/null 2>&1; then
    TEST_CONTAIN_INNER=1
    export TEST_CONTAIN_INNER
    exec systemd-run --user --scope --quiet -p "MemoryMax=${TEST_MEM_MAX:-4G}" \
        -p MemorySwapMax=0 -p OOMPolicy=continue -- sh "$0" "$@"
fi
if [ -z "${TEST_CONTAIN_INNER:-}" ]; then
    if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ] && [ -z "${CI:-}" ] \
        && [ "${TEST_UNCONTAINED:-}" != 1 ]; then
        echo "contain: no systemd user session, so no memory limit; refusing to run (TEST_UNCONTAINED=1 overrides)" >&2
        exit 2
    fi
    echo "contain: no systemd user session; running without a memory limit" >&2
fi
unset TEST_CONTAIN_INNER
TEST_CONTAINED=$here
export TEST_CONTAINED
exec "$@"
