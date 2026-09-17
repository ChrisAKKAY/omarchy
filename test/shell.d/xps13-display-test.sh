#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

detector="$ROOT/bin/omarchy-hw-dell-xps13-dx13260"
leaf="$ROOT/install/hardware/dell-xps13-display.sh"
all="$ROOT/install/hardware/all.sh"
packages="$ROOT/install/omarchy-other.packages"
migration=$(grep -l "dell-xps13-display.sh" "$ROOT"/migrations/*.sh | head -1)

[[ -x $detector ]] || fail "the DX13260 detector exists and is executable"
pass "the DX13260 detector exists and is executable"

grep -q 'run_logged .*hardware/dell-xps13-display.sh' "$all" ||
  fail "the XPS 13 display fix runs during hardware setup"
pass "the XPS 13 display fix runs during hardware setup"

[[ -n $migration ]] || fail "a migration applies the display fix on existing installs"
pass "a migration applies the display fix on existing installs"

grep -qx 'linux-firmware-cirrus' "$packages" ||
  fail "the offline mirror seeds linux-firmware-cirrus for the XPS 13 speaker firmware"
pass "the offline mirror seeds linux-firmware-cirrus for the XPS 13 speaker firmware"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin" "$test_tmp/etc/limine-entry-tool.d"

cat >"$test_tmp/bin/omarchy-hw-match" <<'SH'
#!/bin/bash
[[ ${TEST_PRODUCT_NAME:-} == *"$1"* ]]
SH
cat >"$test_tmp/bin/omarchy-hw-intel-ptl" <<'SH'
#!/bin/bash
[[ ${TEST_INTEL_PTL:-0} == 1 ]]
SH
cat >"$test_tmp/bin/sudo" <<'SH'
#!/bin/bash
exec "$@"
SH
cp "$detector" "$test_tmp/bin/"
chmod +x "$test_tmp"/bin/*

run_leaf() {
  (
    export PATH="$test_tmp/bin:$PATH"
    export TEST_PRODUCT_NAME="$1" TEST_INTEL_PTL="$2"
    export OMARCHY_LIMINE_DROP_IN_DIR="$test_tmp/etc/limine-entry-tool.d"
    # shellcheck disable=SC1090
    source "$leaf"
  )
}

drop_in="$test_tmp/etc/limine-entry-tool.d/dell-xps13-dx13260-display.conf"

run_leaf "XPS 9350" 1
[[ ! -e $drop_in ]] || fail "other Dell models are left alone"
pass "other Dell models are left alone"

run_leaf "XPS 13 DX13260" 0
[[ ! -e $drop_in ]] || fail "a non-Panther-Lake DX13260 is left alone"
pass "a non-Panther-Lake DX13260 is left alone"

run_leaf "XPS 13 DX13260" 1
grep -q 'xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0' "$drop_in" 2>/dev/null ||
  fail "the matching machine gets the PSR1-only kernel command line"
pass "the matching machine gets the PSR1-only kernel command line"

rm -f "$drop_in"
echo 'KERNEL_CMDLINE[default]+=" xe.enable_psr=0"' >"$test_tmp/etc/limine-entry-tool.d/manual.conf"
run_leaf "XPS 13 DX13260" 1
[[ ! -e $drop_in ]] || fail "an existing manual PSR setting is respected"
pass "an existing manual PSR setting is respected"
rm -f "$test_tmp/etc/limine-entry-tool.d/manual.conf"
run_leaf "XPS 13 DX13260" 1

before=$(md5sum "$drop_in")
run_leaf "XPS 13 DX13260" 1
[[ $before == "$(md5sum "$drop_in")" ]] || fail "re-running the leaf is idempotent"
pass "re-running the leaf is idempotent"
