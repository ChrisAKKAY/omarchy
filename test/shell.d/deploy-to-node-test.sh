#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

script="$ROOT/scripts/deploy_to_node.sh"
[[ -f $script ]] || fail "deploy_to_node.sh is present"

! grep -E 'systemctl[[:space:]]+(enable|start|daemon-reload)' "$script" >/dev/null \
  || fail "deploy script must not activate units"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/aaos/scripts" "$test_dir/aaos/config"
export TEST_LOG="$test_dir/calls" AAOS_ROOT="$test_dir/aaos"
printf '%s\n' 'print("ok")' >"$test_dir/aaos/scripts/aaos_c2.py"

cat >"$test_dir/bin/ssh" <<'SH'
#!/bin/bash
echo "ssh $*" >>"$TEST_LOG"
exit 0
SH
cat >"$test_dir/bin/rsync" <<'SH'
#!/bin/bash
echo "rsync $*" >>"$TEST_LOG"
exit 0
SH
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"

! "$script" >"$test_dir/output" 2>&1 || fail "missing destination must refuse"
grep -q usage "$test_dir/output" || fail "missing destination prints usage"

! "$script" 'bad;host' >"$test_dir/output" 2>&1 || fail "metacharacters in destination must refuse"

: >"$TEST_LOG"
"$script" 4of9 >"$test_dir/output" 2>&1 || fail "valid destination should stage" "$(<"$test_dir/output")"
grep -q 'aaos-c2.service' "$TEST_LOG" || fail "stages aaos-c2.service"
grep -q 'aaos-c2-dbus.service' "$TEST_LOG" || fail "stages aaos-c2-dbus.service"
grep -q 'aaos-c2-bus' "$TEST_LOG" || fail "stages aaos-c2-bus binding"
grep -q 'aaos-c2-nftables.service' "$TEST_LOG" || fail "stages aaos-c2-nftables.service"
grep -q 'aaos-c2.nft' "$TEST_LOG" || fail "stages aaos-c2 nftables table"
grep -q 'mnt-aaos-fuse.mount' "$TEST_LOG" || fail "stages mnt-aaos-fuse.mount"
grep -q 'aaos-memory-fuse.service' "$TEST_LOG" || fail "stages FUSE helper unit"
grep -q 'aaos-memory-fuse' "$TEST_LOG" || fail "stages FUSE helper binary"
grep -q 'aaos-c2.conf' "$TEST_LOG" || fail "stages dbus or sysusers config"
grep -q '/opt/aaos/scripts' "$TEST_LOG" || fail "syncs python payload"
grep -q -- '--check' "$TEST_LOG" || fail "runs remote --check"
! grep -q 'systemctl' "$TEST_LOG" || fail "recorded calls must not include systemctl"

pass "deploy_to_node stages and preflights without activating units"
