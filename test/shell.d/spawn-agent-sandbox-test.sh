#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

script="$ROOT/scripts/spawn_agent_sandbox.sh"
[[ -f $script ]] || fail "spawn_agent_sandbox.sh is present"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
export TEST_LOG="$test_dir/calls" TEST_IMAGE_EXISTS=1 TEST_CONTAINER_EXISTS=0 TEST_ENGINE_FAIL=0
cat >"$test_dir/bin/podman" <<'SH'
#!/bin/bash
echo "podman $*" >>"$TEST_LOG"
[[ $TEST_ENGINE_FAIL == 0 ]] || exit 125
case "$*" in
  '--remote=false info') ;;
  '--remote=false image exists '*)
    [[ $TEST_IMAGE_EXISTS == 1 ]] || exit 1
    ;;
  '--remote=false container exists '*)
    [[ $TEST_CONTAINER_EXISTS == 0 ]] || exit 0
    exit 1
    ;;
  '--remote=false run '*) ;;
  *) exit 99 ;;
esac
SH
chmod +x "$test_dir/bin/podman"
export PATH="$test_dir/bin:$PATH"

token='SYNTHETIC_DELEGATION_TOKEN_0000000001'
agent='AG-001'

run_spawn() {
  : >"$TEST_LOG"
  "$script" "$@" >"$test_dir/output" 2>&1
}

! run_spawn && grep -q 'usage:' "$test_dir/output" || fail "missing args fail closed"
! run_spawn "$token" 'not-an-agent' || fail "invalid agent id fail closed"
! run_spawn short "$agent" || fail "short token fail closed"

allow="$test_dir/allowed.txt"
printf '%s\n' 'true' >"$allow"

unset AAOS_AGENT_IMAGE || true
! run_spawn "$token" "$agent" "$allow" || fail "unset image fail closed"
grep -q 'AAOS_AGENT_IMAGE' "$test_dir/output" || fail "unset image names the refusal"

export AAOS_AGENT_IMAGE='localhost/aaos-agent:test'
! run_spawn "$token" "$agent" || fail "missing allowlist fail closed"
TEST_ENGINE_FAIL=1
! run_spawn "$token" "$agent" "$allow" || fail "missing local engine fail closed"
TEST_ENGINE_FAIL=0

TEST_IMAGE_EXISTS=0
! run_spawn "$token" "$agent" "$allow" || fail "missing local image fail closed"
TEST_IMAGE_EXISTS=1

TEST_CONTAINER_EXISTS=1
! run_spawn "$token" "$agent" "$allow" || fail "claimed name fail closed"
TEST_CONTAINER_EXISTS=0

export PATH="$test_dir/bin:/usr/bin:/bin"
run_spawn "$token" "$agent" "$allow" || fail "valid spawn reaches podman run" "$(<"$test_dir/output")"
grep -q -- '--remote=false run' "$TEST_LOG" || fail "uses local engine"
grep -q -- '--network none' "$TEST_LOG" || fail "network is none"
grep -q -- '--pull=never' "$TEST_LOG" || fail "never pulls"
grep -q -- '--cap-drop=ALL' "$TEST_LOG" || fail "drops capabilities"
grep -q -- '--replace=false' "$TEST_LOG" || fail "does not replace foreign containers"
grep -q -- '--entrypoint /run/aaos/entrypoint' "$TEST_LOG" || fail "overrides image entrypoint"
grep -q -- '--tmpfs /usr/bin:ro,noexec' "$TEST_LOG" || fail "masks image /usr/bin as noexec"
grep -q -- '--volume /run/dbus/system_bus_socket:/run/dbus/system_bus_socket:ro' "$TEST_LOG" || fail "bind-mounts the system bus socket read-only"
! grep -q -- 'system_bus_socket:ro,Z' "$TEST_LOG" || fail "must not SELinux-relabel the host D-Bus socket"
grep -q -- 'DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket' "$TEST_LOG" || fail "sets DBUS_SYSTEM_BUS_ADDRESS"
! grep -q -- "$token" "$TEST_LOG" || fail "token must not appear on the podman argv"
grep -q -- 'AAOS_DELEGATION_TOKEN_FILE=/run/aaos/delegation.token' "$TEST_LOG" || fail "token is a file mount, not an env secret"
grep -q -- 'AAOS_ALLOWED_COMMANDS_FILE=/run/aaos/allowed_commands' "$TEST_LOG" || fail "allowlist is mounted read-only"

grep -q 'NoNewPrivileges=true' "$ROOT/default/systemd/system/aaos-c2.service" || fail "c2 unit sets NoNewPrivileges"
grep -q 'ProtectSystem=strict' "$ROOT/default/systemd/system/aaos-c2.service" || fail "c2 unit sets ProtectSystem=strict"
grep -q 'ReadWritePaths=/store /traces' "$ROOT/default/systemd/system/aaos-c2.service" || fail "c2 unit writes only store and traces"
grep -q 'Environment=AAOS_C2_OPERATOR=k' "$ROOT/default/systemd/system/aaos-c2.service" || fail "c2 unit declares AAOS_C2_OPERATOR"
grep -q 'ExecStart=/usr/bin/env python3.12 /opt/aaos/scripts/aaos_c2.py' "$ROOT/default/systemd/system/aaos-c2.service" || fail "c2 ExecStart matches the host brief"
grep -q 'NFTSet=cgroup:inet:aaos:aaos_c2_cgroup' "$ROOT/default/systemd/system/aaos-c2.service" || fail "c2 unit sets NFTSet Option B"
! grep -q '^IPAddressDeny=' "$ROOT/default/systemd/system/aaos-c2.service" || fail "c2 unit must not set IPAddressDeny"
! grep -q '^PrivateNetwork=' "$ROOT/default/systemd/system/aaos-c2.service" || fail "c2 unit must not set PrivateNetwork"
grep -q 'deny own="org.akkay.AAOS"' "$ROOT/etc/dbus-1/system.d/aaos-c2.conf" || fail "dbus default denies owning org.akkay.AAOS"
grep -q 'deny own="org.akkay.aaos.C2"' "$ROOT/etc/dbus-1/system.d/aaos-c2.conf" || fail "dbus default denies owning org.akkay.aaos.C2"
grep -q 'send_member="GetState"' "$ROOT/etc/dbus-1/system.d/aaos-c2.conf" || fail "dbus allows GetState for aaos-ui"
grep -q 'send_interface="org.akkay.aaos.C2.Fetch1"' "$ROOT/etc/dbus-1/system.d/aaos-c2.conf" || fail "dbus allows Fetch1 for aaos-agent"
grep -q 'Where=/mnt/aaos/fuse' "$ROOT/default/systemd/system/mnt-aaos-fuse.mount" || fail "canonical FUSE unit is mnt-aaos-fuse.mount"
grep -q 'Type=fuse.bindfs' "$ROOT/default/systemd/system/mnt-aaos-fuse.mount" || fail "FUSE unit is fuse.bindfs"
grep -q 'WantedBy=multi-user.target' "$ROOT/default/systemd/system/mnt-aaos-fuse.mount" || fail "FUSE mount is enabled for reboot"

pass "spawn sandbox and aaos-c2 units fail closed"
