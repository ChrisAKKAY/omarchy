#!/bin/bash
# AEAC polkit rule. Checks the file is installable and that its LOGIC denies the agent
# runtime, including for an action nobody thought to name.
#
# The logic is exercised against a tiny polkit host written here, because polkitd will
# not evaluate a rule on demand and pkcheck needs a live action and a real subject. The
# stub models the only two semantics the rule relies on: rules run in registration
# order, and the first non-undefined return wins. Anything the stub cannot model, such
# as whether polkitd actually loads the file, is checked separately below.
#
# Needs a JS engine. duktape is what polkit itself embeds; node and qjs are accepted so
# this can run on a workstation. With none present the test SKIPS rather than passing,
# because a logic check that silently did not run is worse than a missing one.

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

rule="$ROOT/etc/polkit-1/rules.d/49-aaos-aeac.rules"
[[ -f $rule ]] || fail "49-aaos-aeac.rules is present"
pass "49-aaos-aeac.rules is present"

# Sorts before the shipped 50-default.rules, or its denials are not authoritative.
base=$(basename -- "$rule")
[[ ${base%%-*} -lt 50 ]] || fail "AEAC rule must sort before 50-default.rules" "$base"
pass "AEAC rule sorts before 50-default.rules"

# The brief described the daemon as UID 985. It is not pinned: sysusers.d says
# `u aaos-c2 -`. A rule keyed to a number would match the wrong account elsewhere.
#
# Comment lines are stripped first. The rule DISCUSSES 985 in prose, explaining why it
# is the wrong thing to match on, and an unstripped grep flagged that explanation as
# the defect it warns about.
code=$(grep -vE '^[[:space:]]*//' "$rule")
if grep -qE '\b985\b' <<<"$code"; then
  fail "AEAC rule must match by user name, not by a UID that sysusers does not pin"
fi
grep -q 'subject.user' "$rule" || fail "AEAC rule must match on subject.user"
pass "AEAC rule matches by name, not by UID"

# The allowlist must stay empty until a decision widens it.
if grep -qE 'ALLOWED_ACTIONS = \[[[:space:]]*"' "$rule"; then
  fail "ALLOWED_ACTIONS is no longer empty; widening AEAC needs a recorded decision"
fi
pass "ALLOWED_ACTIONS is empty"

js=""
for candidate in duk qjs node; do
  if command -v "$candidate" >/dev/null 2>&1; then
    js=$candidate
    break
  fi
done

if [[ -z $js ]]; then
  printf 'ok - # SKIP no JS engine (duk/qjs/node); AEAC logic not exercised\n'
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/harness.js" <<'JS'
var rules = [];
var polkit = {
    Result: { YES: "YES", NO: "NO", AUTH_SELF: "AUTH_SELF", NOT_HANDLED: "NOT_HANDLED" },
    addRule: function (fn) { rules.push(fn); },
    log: function () { }
};
JS
cat "$rule" >>"$work/harness.js"
cat >>"$work/harness.js" <<'JS'

function evaluate(id, user, groups) {
    var subject = {
        user: user,
        isInGroup: function (g) { return (groups || []).indexOf(g) >= 0; }
    };
    for (var i = 0; i < rules.length; i += 1) {
        var verdict = rules[i]({ id: id }, subject);
        if (verdict !== undefined) { return verdict; }
    }
    return "UNHANDLED";
}

var cases = [
    ["pkexec as the daemon", "org.freedesktop.policykit.exec", "aaos-c2", ["aaos-c2"], "NO"],
    ["pkexec as the sandbox user", "org.freedesktop.policykit.exec", "nobody", [], "NO"],
    ["manage systemd units", "org.freedesktop.systemd1.manage-units", "aaos-c2", ["aaos-c2"], "NO"],
    ["reboot the host", "org.freedesktop.login1.reboot", "aaos-c2", ["aaos-c2"], "NO"],
    ["host shell", "org.freedesktop.machine1.host-shell", "aaos-c2", ["aaos-c2"], "NO"],
    ["an unanticipated action", "org.example.future.action", "aaos-c2", ["aaos-c2"], "NO"],
    ["mount a filesystem", "org.freedesktop.udisks2.filesystem-mount", "aaos-c2", ["aaos-c2"], "NO"],
    ["a member of aaos-ui", "org.freedesktop.udisks2.filesystem-mount", "someone", ["aaos-ui"], "NO"],
    ["a human is not touched", "org.freedesktop.udisks2.filesystem-mount", "k", ["wheel"], "UNHANDLED"],
    ["a human may still pkexec", "org.freedesktop.policykit.exec", "k", ["wheel"], "UNHANDLED"]
];

var failures = 0;
for (var i = 0; i < cases.length; i += 1) {
    var c = cases[i];
    var got = evaluate(c[1], c[2], c[3]);
    if (got !== c[4]) {
        failures += 1;
        print("FAIL " + c[0] + " -> " + got + " expected " + c[4]);
    }
}
print(failures === 0 ? "AEAC-LOGIC-OK" : "AEAC-LOGIC-FAILED");
JS

# node has console.log, not print. Give it one.
if [[ $js == node ]]; then
  printf 'var print = console.log;\n' >"$work/run.js"
  cat "$work/harness.js" >>"$work/run.js"
else
  cp "$work/harness.js" "$work/run.js"
fi

out=$("$js" "$work/run.js" 2>&1) || fail "AEAC rule did not evaluate under $js" "$out"
grep -q 'AEAC-LOGIC-OK' <<<"$out" || fail "AEAC logic denied the wrong things" "$out"
pass "AEAC logic denies the agent runtime and leaves people alone ($js)"

# Installed-state checks. Only meaningful once stage_local_linux.sh has run, so their
# absence is reported as a skip rather than quietly treated as success.
installed=/etc/polkit-1/rules.d/49-aaos-aeac.rules
if [[ ! -f $installed ]]; then
  printf 'ok - # SKIP %s not installed; run scripts/stage_local_linux.sh first\n' "$installed"
  exit 0
fi

perms=$(stat -c '%a %U %G' "$installed")
[[ $perms == "644 root root" ]] ||
  fail "installed AEAC rule must be root-owned 0644" "$perms"
pass "installed AEAC rule is root-owned 0644"

if command -v pkaction >/dev/null 2>&1; then
  pkaction >/dev/null 2>&1 || fail "polkit did not accept its configuration"
  pass "polkit accepts its configuration with the AEAC rule installed"
fi
