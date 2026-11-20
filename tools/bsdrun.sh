#!/bin/sh
# bsdrun.sh CMD [ARGS...] - run CMD from the Chimera Linux sysroot, which ships
# the FreeBSD userland (sh, grep, sed, ls, ...) ported to Linux (chimerautils),
# as the FreeBSD differential oracle. Read-only, no network, current directory
# bind-mounted at the same path so relative and absolute paths both work.
#
# One-time setup (the rootfs comes from Chimera.zip, a WSL bundle):
#   mkdir -p $CHIMERA_ROOT && tar -xzf rootfs.tar.gz -C $CHIMERA_ROOT \
#       --no-same-owner --exclude='dev/*'
# CHIMERA_ROOT defaults to /stuff/tmp/chimera-sysroot.
root="${CHIMERA_ROOT:-/stuff/tmp/chimera-sysroot}"
[ -x "$root/bin/sh" ] || { echo "bsdrun: no sysroot at $root" >&2; exit 125; }
exec bwrap --ro-bind "$root" / --proc /proc --dev /dev --tmpfs /tmp \
    --bind "$PWD" "$PWD" --chdir "$PWD" --unshare-all --die-with-parent "$@"
