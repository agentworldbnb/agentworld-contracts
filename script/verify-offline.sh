#!/bin/sh
# Fail closed. Does not install, download, broadcast, or read key material.
# Exit 0 only after isolated forge test -vv, forge build --sizes, and
# forge test -vv --gas-report. Any missing control exits 2 and runs no forge.
set -u

unset PRIVATE_KEY MNEMONIC ETH_KEYSTORE FOUNDRY_ETH_KEYSTORE DEPLOYER_PK \
  ETH_PRIVATE_KEY WALLET_PRIVATE_KEY RPC_URL ETH_RPC_URL BSC_RPC_URL || true

missing=""
add() { missing="${missing}
 - $1"; }

command -v forge >/dev/null 2>&1 || add "forge is not on PATH; this script does not install it"
command -v solc >/dev/null 2>&1 || add "solc is not on PATH; need 0.8.37+commit.f401782d already installed"
command -v timeout >/dev/null 2>&1 || add "timeout for the wall-clock limit is missing"
command -v unshare >/dev/null 2>&1 || add "unshare is missing"
command -v stat >/dev/null 2>&1 || add "stat is missing (needed to identify the scratch block device)"

if command -v solc >/dev/null 2>&1; then
  ver=$(solc --version 2>/dev/null || true)
  echo "$ver" | grep -q "0.8.37" || add "solc exists but is not 0.8.37 (expected 0.8.37+commit.f401782d)"
fi

probe="/sys/fs/cgroup/aw-verify-check-$$"
if mkdir "$probe" 2>/dev/null; then
  rmdir "$probe"
else
  add "cgroup directory cannot be created, so cpu/memory/pids/io limits cannot be applied"
fi

if ! unshare -Urmn --mount-proc true >/dev/null 2>&1; then
  add "unshare cannot mount a fresh /proc, so the read-only mount namespace is incomplete"
fi

if [ -n "$missing" ]; then
  printf '%s\n' "BLOCKED: forge was not started."
  printf '%s\n' "Missing controls:${missing}"
  printf '%s\n' "The command that would run after every check passes is in this file."
  printf '%s\n' "Do not delete a check to make it pass. See docs/PREDEPLOY.md."
  exit 2
fi

set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/aw-verify.XXXXXX")
chmod 700 "$scratch"
mkdir -p "$scratch/home" "$scratch/tmp" "$scratch/cache" "$scratch/out"
toolpath=$(dirname "$(command -v forge)"):$(dirname "$(command -v solc)"):$(dirname "$(command -v sh)"):/usr/bin

cg="/sys/fs/cgroup/aw-verify-$$"
mkdir "$cg"
printf '%s\n' "$$" > "$cg/cgroup.procs"
printf '%s\n' "50000 100000" > "$cg/cpu.max"
printf '%s\n' "2147483648" > "$cg/memory.max"
printf '%s\n' "128" > "$cg/pids.max"
dev=$(stat -c '%d' "$scratch")
major=$(( (dev >> 8) & 4095 ))
minor=$(( (dev & 255) | ((dev >> 12) & 1048320) ))
printf '%s\n' "${major}:${minor} rbps=10485760 wbps=10485760" > "$cg/io.max"

cleanup() {
  rmdir "$cg" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT

# Empty environment. Target and toolchain stay on the read-only bind.
run_isolated() {
  env -i PATH="$toolpath" HOME="$scratch/home" TMPDIR="$scratch/tmp" \
    FOUNDRY_CACHE_DIR="$scratch/cache" FOUNDRY_OUT="$scratch/out" FOUNDRY_OFFLINE=1 \
    timeout --signal=KILL 600 unshare -Urmn --mount-proc sh -c '
    set -eu
    root="$1"
    scratch="$2"
    shift 2
    mkdir -p /work /scratch
    mount --bind "$root" /work
    mount -o remount,bind,ro /work
    mount --bind "$root" "$root"
    mount -o remount,bind,ro "$root"
    mount --bind "$scratch" /scratch
    cd /work
    ulimit -n 256
    ulimit -u 64
    ulimit -f 1048576
    exec "$@"
  ' sh "$root" "$scratch" "$@"
}

run_isolated forge test -vv
run_isolated forge build --sizes
run_isolated forge test -vv --gas-report
printf '%s\n' "ISOLATED_FORGE_OK"
