#!/bin/bash
# Host-mounted PID 1 for AAOS sandboxes. The image entrypoint is not trusted.
# Only names listed in /run/aaos/allowed_commands and present in /run/aaos/bin
# may be exec'd. No path components. No implicit shell.
set -euo pipefail

allow=${AAOS_ALLOWED_COMMANDS_FILE:-/run/aaos/allowed_commands}
bindir=/run/aaos/bin
PATH=$bindir
export PATH
umask 077

refuse() {
  printf '%s\n' "refuse: $*" >&2
  exit 1
}

[[ -f $allow && -d $bindir ]] || refuse "sealed command gate is missing"
(( $# >= 1 )) || refuse "no command"

raw=$1
shift
[[ $raw != */* && $raw != .* && $raw =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
  || refuse "command is outside allowed_commands"

allowed=0
while IFS= read -r line || [[ -n ${line:-} ]]; do
  [[ $line == "$raw" ]] && { allowed=1; break; }
done <"$allow"
(( allowed == 1 )) || refuse "command is outside allowed_commands"

exe=$bindir/$raw
[[ -f $exe && -x $exe && ! -L $exe ]] || refuse "command is not present in the sealed bin"
[[ ! -u $exe && ! -g $exe ]] || refuse "setuid command is forbidden"

exec -a "$raw" "$exe" "$@"
