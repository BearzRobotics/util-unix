#!/bin/sh
# bsdrun.sh CMD [ARGS...] - run CMD from the Chimera Linux sysroot, which ships
# the FreeBSD userland (sh, grep, sed, ls, ...) ported to Linux (chimerautils),
# as the FreeBSD differential oracle. Read-only, no network, current directory
# bind-mounted at /mnt/work (the root is read-only, so the real path cannot be
# recreated); use relative paths.
#
# One-time setup (the rootfs comes from Chimera.zip, a WSL bundle):
#   mkdir -p $CHIMERA_ROOT && tar -xzf rootfs.tar.gz -C $CHIMERA_ROOT \
#       --no-same-owner --exclude='dev/*'
# CHIMERA_ROOT defaults to /stuff/tmp/chimera-sysroot.
root="${CHIMERA_ROOT:-/stuff/tmp/chimera-sysroot}"
[ -x "$root/bin/sh" ] || { echo "bsdrun: no sysroot at $root" >&2; exit 125; }
exec bwrap --ro-bind "$root" / --proc /proc --dev /dev --tmpfs /tmp --tmpfs /mnt \
    --bind "$PWD" /mnt/work --chdir /mnt/work --unshare-all --die-with-parent "$@"
