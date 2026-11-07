#!/bin/sh
# run.sh - boot a throw-away Linux VM under QEMU and run test/vm/init.sh in it
# as root. The guest has nothing but busybox and our own executables, so it can
# exercise what the host tests cannot: a real terminal on standard input,
# root-only ownership changes, and a process with more than 1024 groups.
# Output goes to this terminal (-nographic); nothing is written outside BUILD.
#
# Needs: qemu-system-x86_64 (KVM when it works, else software emulation), gzip, a static
# busybox, and a Linux kernel image with initramfs, devtmpfs and the 8250 serial
# console built in.
#   BUSYBOX  path to a static busybox   (default: search the usual places)
#   KERNEL   path to a bzImage/vmlinuz  (default: search the usual places)
#   BUILD    scratch directory          (default: <repo>/.zig-cache/vm)
#   TARGET   zig target for our binaries (default: x86_64-linux-musl)
#   TIMEOUT  seconds before the VM is killed (default: 180)
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$(dirname "$here")")
BUILD=${BUILD:-$root/.zig-cache/vm}
TARGET=${TARGET:-x86_64-linux-musl}
TIMEOUT=${TIMEOUT:-180}

first() { for p in "$@"; do [ -f "$p" ] && { echo "$p"; return; }; done; }
BUSYBOX=${BUSYBOX:-$(first "$HOME"/.cache/dkconsole-qemu/root/usr/bin/busybox /usr/bin/busybox /bin/busybox)}
KERNEL=${KERNEL:-$(first "$HOME"/de/dkrescue/rootfs/boot/vmlinuz-6.19-dkrescue "$HOME"/.cache/dklilo/vmlinuz)}
[ -n "$BUSYBOX" ] || { echo "no busybox found (set BUSYBOX=)" >&2; exit 2; }
[ -n "$KERNEL" ] || { echo "no kernel found (set KERNEL=)" >&2; exit 2; }
"$BUSYBOX" --list >/dev/null 2>&1 || { echo "$BUSYBOX does not run" >&2; exit 2; }
command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not found" >&2; exit 2; }

rm -rf "$BUILD/ours" "$BUILD/rootfs"
mkdir -p "$BUILD/rootfs/bin" "$BUILD/rootfs/ut" "$BUILD/rootfs/proc" "$BUILD/rootfs/sys" \
         "$BUILD/rootfs/dev" "$BUILD/rootfs/tmp" "$BUILD/rootfs/etc" "$BUILD/rootfs/root"
(cd "$root" && zig build -Doptimize=ReleaseSmall "-Dtarget=$TARGET" --prefix "$BUILD/ours") || exit 2
cp "$BUSYBOX" "$BUILD/rootfs/bin/busybox"
for c in "$BUILD"/ours/bin/*; do cp "$c" "$BUILD/rootfs/ut/$(basename "$c")"; done
cp "$here/init.sh" "$BUILD/rootfs/init"
chmod 755 "$BUILD/rootfs/init" "$BUILD/rootfs/bin/busybox"

(cd "$BUILD/rootfs" && find . | "$BUSYBOX" cpio -o -H newc 2>/dev/null | gzip -1 > "$BUILD/initramfs.gz") || exit 2

# KVM only when QEMU can really start with it (a /dev/kvm node can exist
# without a working module, as under WSL2); otherwise software emulation.
accel="-accel tcg -cpu max"
timeout 5 qemu-system-x86_64 -accel kvm -display none -S -monitor none -nodefaults >/dev/null 2>&1
[ $? -eq 124 ] && accel="-accel kvm -cpu host"
echo "kernel: $KERNEL"; echo "busybox: $BUSYBOX"; echo "target: $TARGET"
# shellcheck disable=SC2086
timeout "$TIMEOUT" qemu-system-x86_64 $accel -m 1024 -smp 2 -nographic -no-reboot \
    -kernel "$KERNEL" -initrd "$BUILD/initramfs.gz" \
    -append "console=ttyS0 rdinit=/init panic=-1 loglevel=3" < /dev/null
