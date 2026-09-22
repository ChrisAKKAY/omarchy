# aaos-cli architecture

Operator-facing terminal client for AAOS C2. Lives in Omarchy. Talks to the daemon only over the system bus. Does not open `/store`, `/traces`, `/knowledge`, or any JSON projection.

This document is the implementation contract for Cursor (Omarchy client) and Antigravity (AAOS method surface). Do not implement the binary until this file is accepted.

## What exists today

`org.akkay.aaos.C2` is already claimed on the system bus by `aaos-c2-dbus.service`. The object `/org/akkay/aaos/C2` currently exports one interface:

```
org.akkay.aaos.C2.Fetch1
  FetchURL(s url, s agent_id) -> (ay body, a{sv} meta)
  ListSources(s agent_id)     -> (aa{sv} sources)
```

That interface is for **sandboxed agents** (`--network none`, uid mapped toward `aaos-agent`). It returns attacker-influenced HTTP bodies. It does not know missions, tasks, health, or approval.

Bus policy in `etc/dbus-1/system.d/aaos-c2.conf` is default-deny. `aaos-agent` may send Fetch1. `aaos-ui` may send `GetState` on the older name `org.akkay.AAOS`. A logged-in operator running a CLI is neither of those unless we say so.

`aaos_c2.py` still opens no socket and still must not. Fetch and (later) control dispatch live in separate method-surface modules. The Omarchy Gio binding (`scripts/aaos-c2-bus`) owns the name and must stay a thin marshaler: it calls `dispatch()`, it does not grow policy.

## The constraint that shapes the CLI

The mission forbids reading JSON files. Therefore `aaos status`, `aaos missions`, and `aaos approve` **cannot ship against Fetch1**. Shipping a pretty terminal that shells out to `cat /store/aaos-c2-state.json` would be a green lie.

So the work is two halves of one contract:

1. **AAOS** grows a second interface on the same object, `org.akkay.aaos.C2.Control1`, with the same shape as Fetch1: stdlib method surface, named errors, CLI-callable without a bus, binding stays dumb.
2. **Omarchy** ships `aaos` as a bus client that calls Control1, formats the reply, and exits non-zero on a named D-Bus error.

Until Control1 is owned and callable, the CLI's only honest behaviour is `refuse: org.akkay.aaos.C2.Control1 is not on the bus`.

## Approaches

### A. Fold into `bin/omarchy` as `omarchy aaos status`

Follows the existing router and metadata comments. Cost: `bin/omarchy` is the desktop command surface; AAOS operator tools are not a desktop group. An `aaos` group in `GROUP_DESCRIPTIONS` advertises AAOS to every Omarchy user, including machines that never run C2.

### B. Standalone `bin/aaos` router, Python + Gio, source under `src/user-space/aaos-cli/` (recommended)

Same idea as `bin/omarchy`, smaller. Python is already how Omarchy owns the C2 name (`scripts/aaos-c2-bus`). Nested `a{sv}` is miserable in `busctl` shell. Fail closed if Gio or the name is missing. Does not join the Omarchy menu.

### C. Bash wrappers around `busctl call`

No extra interpreter story. Rejected for Control1: mission lists are `aa{sv}`, health is `a{sv}`, and approval needs a typed reply. We already chose Gio for the daemon binding for this reason.

**Recommendation: B.** Name the binary `aaos`, not `aaos-cli`, so the user types `aaos status`. Keep the directory name `aaos-cli` as the source tree.

## Bus contract (Control1)

Same name and object as Fetch1. New interface. Fetch1 stays exactly as shipped.

```
bus          system
name         org.akkay.aaos.C2
object       /org/akkay/aaos/C2
interface    org.akkay.aaos.C2.Control1

GetHealth()                      -> (out a{sv} health)
ListMissions()                   -> (out aa{sv} missions)
ListTasks(in s mission_id)       -> (out aa{sv} tasks)
ApproveTask(in s task_id, in s reason) -> (out a{sv} result)
```

`ListTasks` with an empty `mission_id` means "inbox across missions". A missing id is not "all historical tasks".

### What the maps contain (and what they must not)

`GetHealth` keys, all present or the call is a named error, never a partial object:

| Key | Type | Meaning |
|---|---|---|
| `alive` | b | heartbeat written within the unit's interval |
| `operator` | s | declared `AAOS_C2_OPERATOR`, never a verifier |
| `fetch_bound` | b | Fetch1 name still owned |
| `fuse_mounted` | b | `/mnt/aaos/fuse` is a FUSE mount |
| `tick` | x | last heartbeat tick |
| `observed_at` | s | UTC `YYYY-MM-DDTHH:MM:SSZ` |

`ListMissions` row keys: `mission_id`, `title`, `status`, `approval_required` (b), `updated`. No tree paths, no operator registry payload, no tokens.

`ListTasks` row keys: `task_id`, `mission_id`, `title`, `status`, `awaiting_approval` (b), `updated`.

`ApproveTask` result keys: `task_id`, `status`, `approved` (b), `observed_at`. Refusals are named errors, not `approved=false` with a 200-shaped reply.

Forbidden in every Control1 reply: delegation tokens, absolute paths, allowlist internals, fetched HTTP bodies, credentials, other operators' verifiers.

### Named errors (same discipline as Fetch1)

| Error | Means |
|---|---|
| `org.freedesktop.DBus.Error.UnknownMethod` | not a Control1 method |
| `org.freedesktop.DBus.Error.InvalidArgs` | wrong arity or type, or id not shaped like `M-` / `T-` |
| `org.akkay.aaos.C2.Error.NotConfigured` | method surface cannot see missions/tasks (trees missing or store unreadable to the daemon) |
| `org.akkay.aaos.C2.Error.Refused` | approve denied by grant / status / actor |
| `org.akkay.aaos.C2.Error.Unavailable` | daemon is up but the projection the method needs is not (FUSE down, watchdog stale) |

The CLI prints `error_name` and `detail` and exits 1. It does not retry. It does not fall back to files.

## Who may call

Fetch1 and Control1 have opposite callers. Mixing them is how a sandbox starts approving tasks.

```
policy user="aaos-c2"          own org.akkay.aaos.C2
policy user="aaos-agent"       send Fetch1 only
policy group="aaos-ui"         send Control1 (GetHealth, ListMissions, ListTasks, ApproveTask)
policy context="default"       deny own and send to org.akkay.aaos.C2
```

The operator who runs `aaos` must be in `aaos-ui` (already created by `etc/sysusers.d/aaos-c2.conf`). `enable_aaos_host.sh` should add the console user to that group; that is a one-line enablement change, not a CLI feature.

Approve is still not "anyone in aaos-ui". Bus policy is the gate on *reaching* the method. The method surface is the gate on *whether this task may move*. Same split Fetch1 already uses.

## CLI surface

```
aaos status
aaos missions
aaos tasks [mission_id]
aaos approve <task_id> [--reason <text>]
aaos --help
```

`aaos status` = `GetHealth`. `aaos missions` = `ListMissions`. `aaos approve` = `ApproveTask`. `aaos tasks` is required to make approve usable; it is the list `approve` acts on.

No `aaos fetch`. Fetch1 is an agent capability. Putting it on an operator CLI invites pasting URLs into a process that runs as a person.

### Formatting

Default: aligned columns, no JSON, no colour unless stdout is a TTY. `--json` on every command dumps the `a{sv}` / `aa{sv}` as JSON for scripts, still sourced from the bus reply, not from disk.

Empty inbox: one line `no missions` / `no tasks`, exit 0. Bus down: refuse with the D-Bus error, exit 1.

Approve requires `--reason` once we are past a first slice? **No.** First slice: reason is optional and defaults to empty string, because the daemon records actor + task id; a forced essay is a later product choice. The CLI still sends the `s reason` argument (possibly empty) so the signature does not change.

## Layout in this repository

Omarchy has no `src/` tree today. This directory is the exception the mission named. Installed command still lives in `bin/`, which is what `bin/omarchy` and packaging already scan.

```
src/user-space/aaos-cli/
  ARCHITECTURE.md          this file
  aaos.py                  router + formatting (implementation)
  bus.py                   Gio client for Control1 only
  render.py                TTY tables / --json

bin/aaos                   exec python3 of the installed module, omarchy: metadata
                           group=aaos, hidden from desktop groups until C2 is common

test/shell.d/aaos-cli-test.sh
  - refuses if bus name missing (mocked busctl/Gio)
  - does not open AAOS_STORE paths
  - status/missions/approve argv parse
  - grep the client for /store, /traces, HEARTBEAT_NAME, .json  (must not appear as read paths)

etc/dbus-1/system.d/aaos-c2.conf
  - add Control1 allows for group aaos-ui
  - keep Fetch1 aaos-agent-only
```

`scripts/aaos-c2-bus` grows a second exported interface on the same node XML. It must not interpret Control1 arguments. Antigravity adds `aaos_c2_control.py` (name flexible) next to `aaos_c2_dbus.py` with `dispatch()`; the binding imports both.

## Data flow

```
operator tty
  -> bin/aaos
  -> Gio system bus  (DBUS_SYSTEM_BUS_ADDRESS or default)
  -> org.akkay.aaos.C2 /org/akkay/aaos/C2  Control1
  -> aaos-c2-bus (Gio, User=aaos-c2)
  -> aaos_c2_control.dispatch(...)
  -> mission_store / task_store / heartbeat  (daemon side only)
  -> a{sv} reply
  -> format.py
  -> stdout
```

The right-hand side of that arrow (store access) is **not** in this repository. If the CLI process itself `open()`s those trees, the architecture has failed.

## Failure modes worth naming

1. **Control1 not exported yet.** CLI refuses. Do not degrade to files.
2. **Name owned, method missing.** `UnknownMethod`. Same refusal. That is the expected state between this merge and the AAOS Control1 merge.
3. **Operator not in aaos-ui.** AccessDenied from dbus-daemon. CLI prints that name, does not suggest `cat` as a workaround.
4. **Approve against a task not awaiting approval.** `Refused` from the method surface, with a detail the operator can act on (`status is active`, `no grant`, …).
5. **Gio missing.** Refuse at startup, same as `aaos-c2-bus --check`. Do not shell out to `busctl` as a silent fallback; two clients would drift.

## Split of work

| Piece | Owner | Repo |
|---|---|---|
| Control1 method surface, tests, named errors | Antigravity | AkkayAgenticOS |
| Export Control1 from the Gio binding without adding policy | Cursor | omarchy `scripts/aaos-c2-bus` |
| D-Bus policy for aaos-ui → Control1 | Cursor | omarchy `etc/dbus-1/system.d/aaos-c2.conf` |
| `aaos` CLI, formatting, shell tests | Cursor | omarchy `src/user-space/aaos-cli/`, `bin/aaos` |
| Add console user to `aaos-ui` at enablement | Cursor | omarchy `scripts/enable_aaos_host.sh` |
| `aaos_c2.py` stays socket-free | both | do not "just open a port for the CLI" |

## Out of scope for the first CLI slice

- Fetch-on-behalf from the operator terminal
- Interactive TUI / watch mode
- Completions beyond `--help`
- Folding into `omarchy-menu.jsonc`
- Reading HEALTH.md / TASKS.md as a backup
- Implementing Control1 inside `aaos_c2.py`

## Acceptance

- `aaos status` with C2 down: non-zero, names the bus error, no file paths in the message.
- `aaos status` with Fetch1 up and Control1 absent: `UnknownMethod` or a loud `Control1 is not exported`, not an empty fake dashboard.
- `aaos status` with Control1 up: health table sourced from `GetHealth`.
- `aaos missions` prints rows from `ListMissions` only.
- `aaos approve T-001` sends `ApproveTask`; a bus denial and a method refusal are distinguishable.
- `grep` of the CLI source finds no reads of `/store`, `/traces`, or `*.json` as data.

## First implementation cut (after this file is accepted)

1. Antigravity: Control1 `dispatch()` + tests, CLI-callable like `aaos_c2_dbus.py --method GetHealth`.
2. Cursor: export Control1 from `aaos-c2-bus`; widen dbus policy for `aaos-ui`.
3. Cursor: `bin/aaos` + `bus.py` + `format.py`; tests against a fake bus.
4. Together on 4of9: `aaos status` against the live name.
