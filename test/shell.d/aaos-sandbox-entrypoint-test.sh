#!/bin/bash

set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

gate="$ROOT/scripts/aaos-sandbox-entrypoint.sh"
[[ -f $gate ]] || fail "aaos-sandbox-entrypoint.sh is present"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/run/aaos/bin"
printf '%s\n' 'echo' 'true' >"$work/run/aaos/allowed_commands"
cat >"$work/run/aaos/bin/echo" <<'SH'
#!/bin/bash
printf 'sealed:%s\n' "$*"
SH
chmod 555 "$work/run/aaos/bin/echo"
cat >"$work/run/aaos/bin/curl" <<'SH'
#!/bin/bash
printf 'should-not-run\n'
SH
chmod 555 "$work/run/aaos/bin/curl"

copy="$work/gate"
sed -e "s#/run/aaos/bin#$work/run/aaos/bin#g" \
    -e "s#/run/aaos/allowed_commands#$work/run/aaos/allowed_commands#g" \
    "$gate" >"$copy"
chmod 555 "$copy"

out=$("$copy" echo sealed-ok) || fail "allowlisted echo must run"
[[ $out == sealed:sealed-ok ]] || fail "allowlisted echo ran the sealed binary" "$out"

! "$copy" curl https://example.invalid >/dev/null 2>"$work/err" \
  || fail "curl must be rejected even if a curl binary exists in the sealed dir"
grep -q 'outside allowed_commands' "$work/err" || fail "denied command names the refusal"

! "$copy" ../echo >/dev/null 2>"$work/err" || fail "path components must be refused"
! "$copy" >/dev/null 2>"$work/err" || fail "missing command must be refused"

pass "sandbox entrypoint rejects commands outside allowed_commands"
