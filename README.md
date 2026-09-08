# Tunnelbar

A macOS menu bar app for `cloudflared` tunnels. It discovers every connector
running on the machine, reports health from each connector's local metrics
endpoint, and can start and supervise connectors of its own.

Connectors Tunnelbar did not start are read-only: no start, stop, or restart
controls are rendered for them.

## Requirements

- macOS 14 or later
- Swift 6.0+ toolchain (developed against Swift 6.3 / Xcode 26.6)
- `cloudflared` in `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`

## Install

```bash
make install
```

Builds, signs, installs to `/Applications`, and relaunches a running copy.
`make app` builds the bundle without installing it.

Signing prefers a Developer ID Application certificate, falls back to Apple
Development, then to ad-hoc. `make identities` lists what is available. An
ad-hoc signature changes on every build, which causes repeated Keychain
prompts and unreliable login-item registration; any real certificate avoids
both. Sharing the app with another Mac requires Developer ID plus
notarisation. The hardened runtime is already enabled.

### Make targets

| Target | Effect |
|---|---|
| `make build` | Build all targets |
| `make test` | Run the test suite |
| `make check` | Test, then print live discovery |
| `make discover` | Print discovery JSON once |
| `make watch` | Print discovery JSON every 10s |
| `make app` | Build and sign `Tunnelbar.app` |
| `make install` | Build, sign, install to `/Applications` |
| `make identities` | List code signing identities |
| `make release` | Optimised build |
| `make clean` | Remove build products |

## The menu

The status icon shows the worst health across all discovered connectors.
Icons differ in shape as well as colour.

| Icon | Meaning |
|---|---|
| Check | All expected connections up (4 of 4) |
| Triangle | 1–3 connections |
| Octagon | 0 connections |
| Question mark | Metrics port not resolved |
| Dotted circle | Nothing running |

Each connector row shows its tunnel name (or supervisor label, or pid),
ready connection count, edge locations, uptime, pid, and an ownership badge.
Rows offer **Copy connector ID**, and **Stop** only when Tunnelbar owns the
connector.

Further sections appear when relevant:

- **Down connectors** Tunnelbar manages, with restart status and a **Forget**
  action.
- **Not running on this Mac** — account tunnels with no local connector.
  Requires an API token.
- **Local services** — listening TCP ports, and which tunnel hostnames reach
  them. Requires an API token.
- **Quick tunnel** — start an anonymous tunnel against a local port.

The menu refreshes on open. Background polling runs every 10s while anything
is running or managed, and backs off to 120s when the machine is idle. The
account tunnel list refreshes every 60s; **Refresh** forces it immediately.

## Ownership

| Ownership | Source | Controls |
|---|---|---|
| `tunnelbar` | Started by this app | Stop |
| `launchd` | A LaunchAgent or LaunchDaemon | none |
| `homebrew` | `brew services` | none |
| `shell` | Started from a shell | none |
| `unknown` | Not identified | none |

Ownership resolution fails closed: anything not positively identified as
app-owned is read-only. A registry entry is honoured only when a live process
exists at that pid, its start time matches the recorded one, and it is still
a `cloudflared` connector — pids are recycled, and a stale entry would
otherwise attach a Stop button to an unrelated process.

`ConnectorLauncher` is the only code path that starts or signals a process,
and it can only exec a binary named `cloudflared`. `launchctl` and `brew` are
reachable only through `ReadOnlyCommand`, which allowlists executables and
verbs; `bootout`, `kickstart`, and `brew services start` are not in it.

## Supervision

Connectors Tunnelbar started are restarted when they exit unexpectedly.

- Backoff: 0s, 2s, 4s, 8s … capped at 300s. It does not give up.
- A run of at least 60s resets the failure count.
- A failed restart attempt counts as a failure and applies the backoff.
- After 3 consecutive failures the menu marks the connector as failing.
- **Stop** removes the entry, so a deliberate stop is not undone.
- Quick tunnels do not auto-restart by default: a restarted quick tunnel gets
  a different public hostname.

Supervision runs on the poll, so it also covers connectors that outlived a
Tunnelbar restart. Enable **Launch at login** in Settings for connectors to
return after a reboot.

## Configuration

Settings holds four things:

- **Launch at login** — `SMAppService`. Registration records the exact bundle
  path shown in the panel; reinstalling elsewhere requires re-enabling.
- **Cloudflare API token** — enables the account tunnel list, friendly names,
  and service exposure. Verified against the API before it is stored.
- **Account ID** — 32 hex characters. Required alongside the token: a token
  scoped to Cloudflare Tunnel: Read cannot list accounts, and Cloudflare
  returns an empty list rather than an error. Adding a tunnel token fills this
  in automatically.
- **Tunnel tokens** — one per tunnel, each allowing Tunnelbar to start a
  connector for it. The tunnel ID is read from the token.

### API token

**Get API token…** opens the dashboard token page. Choose *Create Custom
Token* and add one permission:

```
Account → Cloudflare Tunnel → Read
```

Cloudflare has no OAuth flow that issues API tokens to third-party apps, and
the dashboard's `permissionGroupKeys` parameter takes undocumented keys that
cannot be looked up at runtime, so the permission is not preselected.

## Command line

### `tunnelbar-discover`

Read-only discovery as JSON. Never starts, stops, or signals a connector.

```
tunnelbar-discover [--pretty|--compact] [--watch SECONDS]
```

Exit code is `1` if any connector is down, otherwise `0`. A machine with no
connectors exits `0`.

```json
{
  "schemaVersion": 2,
  "overallHealth": "healthy",
  "connectors": [
    {
      "pid": 10269,
      "ownership": "launchd",
      "ownerLabel": "com.example.tunnel",
      "isManageable": false,
      "health": "healthy",
      "uptimeSeconds": 3841,
      "redactedArguments": ["cloudflared", "tunnel", "run", "--token", "<redacted>"],
      "metrics": {
        "port": 20241,
        "connectorID": "00000000-0000-0000-0000-000000000000",
        "readyConnections": 4,
        "haConnections": 4,
        "edgeConnections": [{ "connection_id": "0", "edge_location": "mia09" }],
        "totalRequests": 640,
        "concurrentRequests": 0
      }
    }
  ],
  "localServices": [
    {
      "port": 3000,
      "address": "127.0.0.1",
      "pid": 9933,
      "processName": "node",
      "isLoopbackOnly": true,
      "catalog": null
    }
  ],
  "notes": [{ "kind": "localConfig", "detail": "…" }]
}
```

### `Tunnelbar.app/Contents/MacOS/Tunnelbar`

The app binary accepts commands that print and exit without opening the UI.

| Flag | Effect |
|---|---|
| `--services` | List local services and the tunnel hostnames reaching them |
| `--api-check` | Exercise each Cloudflare API call and report per-call results |
| `--list-managed` | Print the registry: what is managed, live state, backoff |
| `--start-tunnel <id>` | Start a connector for a tunnel token in the Keychain |
| `--token-url` | Print the dashboard token URL and required permission |
| `--login-item-status` | Print login item state and registered bundle path |
| `--enable-login-item` | Register as a login item |
| `--disable-login-item` | Unregister |

## How discovery works

**Connectors.** `libproc` enumerates pids and keeps those whose executable is
named `cloudflared` with a connector-shaped argv: `tunnel run`, or `--token`,
`--url`, or `--hello-world`. `access` and `tail` are excluded — both take
`--url` without being connectors.

**Metrics port.** Started without `--metrics`, `cloudflared` binds a random
loopback port that changes on every restart. Tunnelbar reads the process's own
listening TCP sockets through `proc_pidinfo`, then probes each candidate by
response shape. No subprocess, and no access to the connector's log required.

You can pin the port with `--metrics 127.0.0.1:20241`, but this does not
require it.

**Health.** `/ready` gives the connector ID and ready connection count;
`/metrics` gives edge locations and counters in Prometheus text format, parsed
without a dependency. `/ready` is read at any HTTP status, because a connector
with zero connections answers 503 with the same body.

**Ownership.** LaunchAgent and LaunchDaemon plists referencing `cloudflared`
are read, and `launchctl print` supplies each job's current pid. Homebrew comes
from `brew services list --json`, probing standard prefixes because `brew` is
often absent from a non-interactive `PATH`.

**Docker.** Docker Desktop runs containers in a VM, so containerised connectors
do not appear in this machine's process table and are not discovered at all.
Detecting them would require querying the Docker socket.

**Local config.** `~/.cloudflared/` is listed, never opened. Its absence is
normal for token-based tunnels and is not reported as an error.

## Local services

`--services`, and the menu's Local services section, list listening TCP ports
with the owning process, and the tunnel hostnames that reach them. Ingress
rules come from the Cloudflare API, since a token-based tunnel's config lives
in Cloudflare rather than `~/.cloudflared/config.yml`.

```
3000  node (pid 9933)  [loopback]
     → https://example.com  (tunnel web-origin)
5000  ControlCenter (pid 896)  [all interfaces]
     AirPlay Receiver
     Commonly collides with dev servers on 5000.
     not exposed through any tunnel
```

Two kinds of reach are reported separately: **published** means a tunnel
hostname routes to the port from the internet; **all interfaces** means the
service is bound to a wildcard address and reachable from the local network
with no tunnel involved.

An ingress rule routing to another host does not mark a local port of the same
number as published. Catch-all rules (`http_status:404`, `bastion`) are not
counted as bindings.

Common macOS services are named where recognised. Unrecognised services are
left undescribed. Only processes owned by the current user are visible without
elevation, so root daemons do not appear; discovery notes this.

## Secrets

Two secrets are stored, as Keychain generic passwords under service
`com.adolfsson.tunnelbar`:

| Secret | Account | Purpose |
|---|---|---|
| API token | `cloudflare-api-token` | Read account tunnel state |
| Tunnel token | `tunnel-token:<tunnelID>` | Start a connector for one tunnel |

Items are `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so they are not
synced to iCloud Keychain. Account IDs, tunnel IDs, and connector IDs are not
secrets and are stored in `UserDefaults`.

Tunnel tokens reach `cloudflared` through the `TUNNEL_TOKEN` environment
variable, not `--token`. Process arguments appear in `ps` output for every user
on the machine; the environment does not. Child processes receive a minimal
environment rather than an inherited one.

Stored secrets are never displayed, read back into a field, or placed on the
pasteboard. The settings panel reports only whether a secret exists.

Arguments read from other processes are redacted at the point of capture, so
no unredacted argv exists in a `Connector` value. Redaction covers
`--token VALUE` and `--token=VALUE` forms plus bare token-shaped arguments.
The environment block of other processes is never read.

## Files

| Path | Contents |
|---|---|
| `~/Library/Application Support/Tunnelbar/owned.json` | Managed connector registry |
| `~/Library/Application Support/Tunnelbar/logs/` | Logs for connectors Tunnelbar started (mode 0600) |

## Development

```bash
swift build
swift test
```

Integration tests start real connectors and touch the real Keychain. They are
off by default:

```bash
TUNNELBAR_INTEGRATION=1 swift test
```

The package builds headlessly; there is no `.xcodeproj`.

## Status

Implemented: discovery, menu bar UI, lifecycle for app-owned connectors, quick
tunnels, token-based starts, respawn, launch at login, Keychain storage,
account-wide tunnel list, and local service exposure.

Not implemented: notifications, and editing ingress rules, DNS records, or
Access policies.

## License

MIT — see [LICENSE](LICENSE).
