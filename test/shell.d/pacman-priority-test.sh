#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command pacman-conf
MIGRATION="$ROOT/migrations/1789574960.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# The migration operates only on these fixtures and never invokes real sudo.
sudo() {
  "$@"
}
export -f sudo

run_migration() {
  OMARCHY_PACMAN_CONF="$1" bash -euo pipefail "$MIGRATION"
}

assert_preferred() {
  local repos
  repos=$(pacman-conf --config "$1" --repo-list)
  [[ $repos == $'omarchy\ncore\nextra\nmultilib' ]] || fail "unexpected repository order: $repos"
}

for channel in edge rc stable; do
  # Avoid dependence on the test machine having an Arch mirrorlist installed.
  sed 's|Include = /etc/pacman.d/mirrorlist|Server = https://example.invalid/$repo/os/$arch|' \
    "$ROOT/default/pacman/pacman-$channel.conf" >"$TEST_DIR/$channel.conf"
  assert_preferred "$TEST_DIR/$channel.conf"
  run_migration "$TEST_DIR/$channel.conf"
  [[ ! -e $TEST_DIR/$channel.conf.omarchy-priority.bak ]] || fail "already preferred $channel config was rewritten"
  pass "$channel default prefers Omarchy and needs no migration"
done

cat >"$TEST_DIR/custom.conf" <<'EOF'
# Personal configuration
[options]
Architecture = auto
IgnorePkg = example
ParallelDownloads = 9

[local]
Server = file:///srv/packages
SigLevel = Never

[core]
Server = https://arch.example/$repo/os/$arch

[extra]
Server = https://arch.example/$repo/os/$arch

[omarchy]
# keep my server and signature policy
Server = https://custom.example/rc/$arch
SigLevel = Required
Usage = Sync Search Install Upgrade

[personal]
Server = https://personal.example/$arch
EOF
cat >"$TEST_DIR/expected.conf" <<'EOF'
# Personal configuration
[options]
Architecture = auto
IgnorePkg = example
ParallelDownloads = 9

[local]
Server = file:///srv/packages
SigLevel = Never

[omarchy]
# keep my server and signature policy
Server = https://custom.example/rc/$arch
SigLevel = Required
Usage = Sync Search Install Upgrade

[core]
Server = https://arch.example/$repo/os/$arch

[extra]
Server = https://arch.example/$repo/os/$arch

[personal]
Server = https://personal.example/$arch
EOF
cp "$TEST_DIR/custom.conf" "$TEST_DIR/original.conf"
chmod 640 "$TEST_DIR/custom.conf"
ln -s "$TEST_DIR/custom.conf" "$TEST_DIR/link.conf"
run_migration "$TEST_DIR/link.conf"
[[ -L $TEST_DIR/link.conf ]] || fail "configuration symlink was replaced"
[[ $(stat -c %a "$TEST_DIR/custom.conf") == "640" ]] || fail "configuration permissions changed"
cmp -s "$TEST_DIR/expected.conf" "$TEST_DIR/custom.conf" || fail "custom repositories or options changed"
cmp -s "$TEST_DIR/original.conf" "$TEST_DIR/custom.conf.omarchy-priority.bak" || fail "original configuration was not backed up"
[[ $(pacman-conf --config "$TEST_DIR/custom.conf" --repo-list) == $'local\nomarchy\ncore\nextra\npersonal' ]] || fail "custom repository precedence changed"
pass "migration preserves custom blocks, permissions, symlinks, and original backup"

run_migration "$TEST_DIR/custom.conf"
cmp -s "$TEST_DIR/expected.conf" "$TEST_DIR/custom.conf" || fail "second migration changed configuration"
cmp -s "$TEST_DIR/original.conf" "$TEST_DIR/custom.conf.omarchy-priority.bak" || fail "second migration replaced backup"
[[ ! -e $TEST_DIR/custom.conf.omarchy-priority.bak.~1~ ]] || fail "second migration created a backup"
pass "migration is idempotent"

cat >"$TEST_DIR/no-omarchy.conf" <<'EOF'
[options]
Architecture = auto
[core]
Server = https://arch.example/$repo/os/$arch
EOF
cp "$TEST_DIR/no-omarchy.conf" "$TEST_DIR/no-omarchy.expected"
run_migration "$TEST_DIR/no-omarchy.conf"
cmp -s "$TEST_DIR/no-omarchy.expected" "$TEST_DIR/no-omarchy.conf" || fail "missing Omarchy repository was added"
[[ ! -e $TEST_DIR/no-omarchy.conf.omarchy-priority.bak ]] || fail "configuration without Omarchy was rewritten"
pass "intentionally absent Omarchy repository stays absent"

for config in "$TEST_DIR/stable.conf" "$TEST_DIR/no-omarchy.conf"; do
  (
    set +e +u
    set +o pipefail
    trap 'echo caller-trap >"$TEST_DIR/caller-trap"' EXIT
    before_options=$(set +o)
    before_trap=$(trap -p EXIT)
    export OMARCHY_PACMAN_CONF="$config"
    source "$MIGRATION"
    [[ $(set +o) == "$before_options" ]] || fail "sourced migration changed caller options"
    [[ $(trap -p EXIT) == "$before_trap" ]] || fail "sourced migration replaced caller trap"
    touch "$TEST_DIR/source-returned"
  )
  [[ -e $TEST_DIR/source-returned ]] || fail "sourced migration exited its caller"
  [[ -e $TEST_DIR/caller-trap ]] || fail "sourced migration removed caller trap"
  rm "$TEST_DIR/source-returned" "$TEST_DIR/caller-trap"
done
pass "sourcing no-op migrations preserves caller execution, shell options, and traps"

cat >"$TEST_DIR/arch.conf" <<'EOF'
[core]
Server = https://arch.example/$repo/os/$arch
EOF
cat >"$TEST_DIR/includes.conf" <<EOF
[options]
Architecture = auto
Include = $TEST_DIR/arch.conf
[omarchy]
Server = https://custom.example/stable/\$arch
EOF
cp "$TEST_DIR/includes.conf" "$TEST_DIR/includes.expected"
if run_migration "$TEST_DIR/includes.conf" >"$TEST_DIR/include.log" 2>&1; then
  fail "repository defined through Include was silently left before Omarchy"
fi
cmp -s "$TEST_DIR/includes.expected" "$TEST_DIR/includes.conf" || fail "unsupported included configuration was changed"
[[ ! -e $TEST_DIR/includes.conf.omarchy-priority.bak ]] || fail "unsupported included configuration was backed up"
grep -q 'included pacman configuration' "$TEST_DIR/include.log" || fail "unsupported Include failure needs actionable instructions"
pass "included repository ordering fails safely without rewriting configuration"
