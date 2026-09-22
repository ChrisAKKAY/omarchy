#!/bin/bash
# Rootless Podman sandbox for one AAOS agent. Called by bounded_execution.py.
# Fail-closed: missing args, empty allowlist, root, remote engine, missing image,
# or a token that does not look like a delegation token all refuse before podman run.
#
# Usage: spawn_agent_sandbox.sh <delegation-token> <agent-id> <allowed-commands-file>
# Token is never logged. allowed_commands is enforced here, not by the workload.
set -euo pipefail

usage() {
  printf '%s\n' "usage: spawn_agent_sandbox.sh <delegation-token> <agent-id> <allowed-commands-file>" >&2
  exit 2
}

refuse() {
  printf '%s\n' "refuse: $*" >&2
  exit 1
}

NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
MAX_COMMANDS=16

(( $# == 3 )) || usage
token=$1
agent_id=$2
allow_src=$3

if (( EUID == 0 )); then
  refuse "rootful spawn is forbidden"
fi

if [[ ! $agent_id =~ ^AG-[0-9]{3,}$ ]]; then
  refuse "agent-id is not a bounded-execution agent"
fi

if [[ ! $token =~ ^[A-Za-z0-9._-]{32,128}$ ]]; then
  refuse "delegation token failed closed validation"
fi

[[ -f $allow_src ]] || refuse "allowed_commands file is missing"

command -v podman >/dev/null || refuse "podman missing"

if ! podman --remote=false info >/dev/null 2>&1; then
  refuse "rootless local podman is unavailable"
fi

image=${AAOS_AGENT_IMAGE:-}
[[ -n $image ]] || refuse "AAOS_AGENT_IMAGE is unset (no default image)"

if ! podman --remote=false image exists "$image"; then
  refuse "sandbox image is not present locally"
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
gate=$here/aaos-sandbox-entrypoint.sh
[[ -f $gate ]] || refuse "aaos-sandbox-entrypoint.sh is missing"

mapfile -t commands < <(sed -e 's/[[:space:]]*$//' -e '/^$/d' -- "$allow_src")
(( ${#commands[@]} >= 1 )) || refuse "allowed_commands is empty"
(( ${#commands[@]} <= MAX_COMMANDS )) || refuse "allowed_commands exceeds $MAX_COMMANDS"

declare -A seen=()
for cmd in "${commands[@]}"; do
  [[ $cmd =~ $NAME_RE && $cmd != */* ]] || refuse "allowed command is not a sealed name"
  [[ ! -v seen[$cmd] ]] || continue
  seen[$cmd]=1
done

runtime_dir=${XDG_RUNTIME_DIR:-/tmp}
work=$(mktemp -d "$runtime_dir/aaos-sandbox.$agent_id.XXXXXX")
cleanup() {
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
chmod 700 "$work"
mkdir -p "$work/bin"
chmod 700 "$work/bin"

umask 077
printf '%s' "$token" >"$work/delegation.token"
chmod 400 "$work/delegation.token"
unset token

: >"$work/allowed_commands"
declare -A copied=()
for cmd in "${commands[@]}"; do
  [[ ! -v copied[$cmd] ]] || continue
  src=$(type -P -- "$cmd" || true)
  [[ -n $src && -f $src && -x $src ]] || refuse "allowed command is not a host binary: $cmd"
  [[ ! -u $src && ! -g $src ]] || refuse "setuid command cannot be sealed: $cmd"
  cp -f -- "$src" "$work/bin/$cmd"
  chmod 555 "$work/bin/$cmd"
  printf '%s\n' "$cmd" >>"$work/allowed_commands"
  copied[$cmd]=1
done
chmod 400 "$work/allowed_commands"
chmod 555 "$work/bin"
cp -f -- "$gate" "$work/entrypoint"
chmod 555 "$work/entrypoint"

name="aaos-agent-${agent_id}"
if podman --remote=false container exists "$name"; then
  refuse "container name already claimed"
fi

fuse_args=()
if [[ -d /mnt/aaos/fuse ]] && findmnt -n -M /mnt/aaos/fuse >/dev/null 2>&1; then
  fuse_args=(--volume /mnt/aaos/fuse:/mnt/aaos/fuse:ro,Z)
fi

# Image command dirs are noexec so the workload cannot execve outside the sealed bin.
# Entrypoint is the host gate, not the image's. PATH inside is only /run/aaos/bin.
# Isolation stays network-none. The system bus socket is a filesystem object, so
# fetch-on-behalf is a bind mount, not a route. Do not label the socket with :Z —
# that would relabel the host bus out from under dbus-daemon.
podman --remote=false run \
  --replace=false \
  --name "$name" \
  --pull=never \
  --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --tmpfs /bin:ro,noexec,nosuid,size=64k \
  --tmpfs /sbin:ro,noexec,nosuid,size=64k \
  --tmpfs /usr/bin:ro,noexec,nosuid,size=64k \
  --tmpfs /usr/sbin:ro,noexec,nosuid,size=64k \
  --tmpfs /usr/local/bin:ro,noexec,nosuid,size=64k \
  --tmpfs /usr/local/sbin:ro,noexec,nosuid,size=64k \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --user 65534:65534 \
  --network none \
  --hostname sandbox \
  --env PATH=/run/aaos/bin \
  --env AAOS_AGENT_ID="$agent_id" \
  --env AAOS_DELEGATION_TOKEN_FILE=/run/aaos/delegation.token \
  --env AAOS_ALLOWED_COMMANDS_FILE=/run/aaos/allowed_commands \
  --env DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket \
  --volume "$work/delegation.token:/run/aaos/delegation.token:ro,Z" \
  --volume "$work/allowed_commands:/run/aaos/allowed_commands:ro,Z" \
  --volume "$work/bin:/run/aaos/bin:ro,Z" \
  --volume "$work/entrypoint:/run/aaos/entrypoint:ro,Z" \
  --volume /run/dbus/system_bus_socket:/run/dbus/system_bus_socket:ro \
  "${fuse_args[@]+"${fuse_args[@]}"}" \
  --entrypoint /run/aaos/entrypoint \
  "$image" \
  "${commands[0]}"
