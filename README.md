# AAP 2.6 Containerized Health Check

`aap26-healthcheck.sh` runs a role-aware health check against a single
**containerized Ansible Automation Platform 2.6** node. You tell it what the
node is (`--nodetype`), and it runs a common set of system/Podman checks plus
the checks specific to that role, then prints a PASS / WARN / FAIL summary and
exits non-zero if anything failed.

It is read-only: it inspects containers, listeners, secrets, logs, and SELinux
state. It never restarts services, edits config, or writes files.

## Requirements

- **Run as the install user**, not root. Containerized AAP 2.6 runs as rootless
  Podman under a dedicated user with systemd *user* units. Run this in a real
  login session so `XDG_RUNTIME_DIR` is set (e.g. `su - <user>`,
  `machinectl shell`, or an SSH login as that user) — `sudo su` does not set it
  up correctly and `systemctl --user` / rootless Podman will misbehave.
- **bash 4.4+** (RHEL 9/10 ship 5.x).
- **Podman 4.5+** — the secret validation uses `podman secret exists`.
- **iproute2** (`ss`) for the port-listener checks.
- **curl** for the API probes.
- Optional: `rpm` (container-selinux check), `ausearch`/`journalctl` access
  (SELinux denial scan), `sestatus` (policy detail).

The script degrades gracefully when an optional tool or permission is missing —
it reports INFO/WARN rather than crashing.

Before any checks run, the script validates that the required RPMs — `iproute`
(provides `ss`; accepted as `iproute2` on non-RHEL hosts), `curl`, and `podman`
— are installed, and aborts with exit code `1` if any are missing.

## Installation

```bash
chmod +x aap26-healthcheck.sh
```

If your filesystem is mounted `noexec`, run it with `bash aap26-healthcheck.sh ...`.

## Usage

```
./aap26-healthcheck.sh --nodetype <controller|gateway|hub|eda|execution|all> [options]
```

### Options

| Option | Description |
|---|---|
| `--nodetype TYPE` | **Required.** Role of this node (see below). |
| `--api-host HOST` | Base host for API probes. Default `https://localhost`. |
| `--token TOKEN` | Bearer token for authenticated API calls. Visible in `ps`/history — prefer the options below. |
| `--token-file FILE` | Read the bearer token from the first line of `FILE`. |
| `--external-db` | The database is external/managed, not a local container. Skips the `postgresql_admin_password` secret requirement. Auto-detected when no local postgres container is found. |
| `--db-host HOST[:PORT]` | External database host (implies `--external-db`). Enables a TCP reachability test to the DB; port defaults to 5432. |
| `--external-redis` | Redis is external/managed, not a local container. Auto-detected when no local redis container is found. |
| `--redis-host HOST[:PORT]` | External Redis host (implies `--external-redis`). Enables a TCP reachability test to Redis; port defaults to 6379. |
| `--log-lines N` | Lines of container log to scan for errors. Default `200`. |
| `--verbose`, `-v` | Show extra detail (full container list, log excerpts, denial samples). |
| `--no-color` | Disable colored output (useful for cron/CI logs). |
| `--help`, `-h` | Show usage. |

### Node types

| Value | Node |
|---|---|
| `controller` | Automation Controller |
| `gateway` | Platform Gateway (+ Envoy proxy) |
| `hub` | Automation Hub (Pulp) |
| `eda` | Event-Driven Ansible |
| `execution` | Execution node (Receptor) |
| `all` | All-in-one / single-node deployment (runs every role check) |

### Examples

```bash
# Single-node / all-in-one box
./aap26-healthcheck.sh --nodetype all --verbose

# A dedicated gateway node
./aap26-healthcheck.sh --nodetype gateway

# Controller node, authenticated probes via a token file
./aap26-healthcheck.sh --nodetype controller --token-file ~/.aap/token

# Token via environment variable, custom API host
AAP_TOKEN="$(cat ~/.aap/token)" \
  ./aap26-healthcheck.sh --nodetype controller --api-host https://aap26m.sudo.net
```

## Authentication

Several API endpoints (e.g. the controller metrics endpoint) only return real
data when authenticated. Provide a gateway-issued bearer token in one of three
ways, in precedence order:

1. `--token TOKEN`
2. `--token-file FILE`
3. `$AAP_TOKEN` environment variable

The token is never printed; preflight only reports its source. Passing it on the
command line triggers a warning because it is visible in the process list and
shell history — prefer `--token-file` or `$AAP_TOKEN`.

**How results are interpreted:** any HTTP response (including `401`/`403`) proves
a service is listening, so a reachable-but-unauthenticated endpoint is a PASS
when no token is supplied. When a token *is* supplied, a `401`/`403` becomes a
WARN, since a rejected token points at an invalid, expired, or under-scoped
credential rather than a dead service. Only a refused/timed-out connection is a
FAIL.

## What it checks

### Common checks (every node type)

- **Preflight** — Podman present and reachable, rootless flag, running user,
  `XDG_RUNTIME_DIR`, and the API auth mode.
- **Hostname (FQDN)** — the system hostname must be a fully qualified domain
  name (FAIL on a short name, IP address, or `localhost*`), with best-effort
  checks that `hostname -f` and forward resolution agree. AAP requires every
  node to have a resolvable FQDN; run the script on each node to cover them all.
- **System resources** — available memory, load average, and disk usage on `/`,
  `/var`, `$HOME`, and the Podman graphroot.
- **SELinux** — runtime mode (Enforcing = PASS, Permissive = WARN,
  Disabled = FAIL); persistent `/etc/selinux/config` vs runtime (reboot safety);
  loaded policy is `targeted`; `container-selinux` installed; a running
  container is actually confined as `container_t`; and a best-effort scan of
  today's AVC denials.
- **Systemd user units** — flags failed `systemctl --user` units.
- **Containers** — running/total counts, stopped containers, unhealthy
  containers, and restart-loop detection.
- **Podman secrets** — node-aware required-secret validation (see below).
- **Log error scan** — scans the last `--log-lines` of each AAP container for
  error signatures (`error`, `critical`, `traceback`, `InvalidToken`, etc.).
- **Network listeners** — validates the ports this node should be listening on
  (see below).

### Role-specific checks

- **gateway** — gateway and Envoy/proxy containers; gateway API and login page
  reachability; an explicit scan for Fernet `InvalidToken` (the secret-key
  mismatch failure mode); Redis; PostgreSQL.
- **controller** — web/task containers; `/api/controller/v2/ping/`; dispatcher
  activity; the metrics endpoint; Redis; PostgreSQL; Receptor container.
- **hub** — Pulp api/content/worker containers; the unauthenticated Pulp status
  endpoint (parsed for DB-connected + online worker count); Redis; PostgreSQL.
- **eda** — EDA api/worker containers; the EDA API; Redis; PostgreSQL.
- **execution** — Receptor container; execution environment images present; and
  a warning if control-plane containers are running where they shouldn't be.

Container discovery is pattern-based off `podman ps`, so it adapts to naming
differences. If a component's container name doesn't match, you'll see a
"no X container matched" warning rather than a silent miss.

## Podman secret validation

Each expected secret is checked with `podman secret exists NAME`; only exit code
0 counts as present, anything else is a FAIL. Secrets are grouped by component
and validated according to node type.

| Group | Secrets |
|---|---|
| database | `postgresql_admin_password` |
| gateway | `gateway_secret_key`, `gateway_db_password`, `gateway_admin_password`, `gateway_redis_url` |
| controller | `controller_channels`, `controller_resource_server`, `controller_postgres`, `controller_secret_key` |
| eda | `eda_resource_server`, `eda_secret_key`, `eda_admin_password`, `eda_db_password` |
| hub | `hub_secret_key`, `hub_collection_signing_passphrase`, `hub_settings`, `hub_database_fields`, `hub_resource_server`, `hub_container_signing_passphrase` |

| Node type | Validated groups |
|---|---|
| gateway | database + gateway |
| controller | database + controller |
| hub | database + hub |
| eda | database + eda |
| execution | none (Receptor uses TLS certs, not these secrets) |
| all | every group |

**External / managed database:** when PostgreSQL runs outside AAP, the script
detects it automatically (no local postgres container) — or you can be explicit
with `--external-db`. In that mode it does **not** require the
`postgresql_admin_password` secret (which only exists for an AAP-managed local
DB), so the per-node connection secrets (`controller_postgres`,
`gateway_db_password`, `eda_db_password`, `hub_database_fields`) are still
validated, but the admin secret is skipped instead of producing a false FAIL.
Add `--db-host HOST[:PORT]` to also run a TCP reachability test from the node to
the external database (the 5432 source flow from the ports table):

```bash
./aap26-healthcheck.sh --nodetype controller --db-host db.example.com
./aap26-healthcheck.sh --nodetype all --db-host 10.0.0.20:5432
```

**External / managed Redis:** handled the same way. It's auto-detected when no
local redis container is present (or set `--external-redis`), in which case the
absence is reported as expected (INFO) rather than a warning. Add
`--redis-host HOST[:PORT]` for a TCP reachability test from the node to the
external Redis. There is no Redis equivalent of `postgresql_admin_password` to
skip — `gateway_redis_url` is the connection config and is validated in both
local and external modes.

```bash
./aap26-healthcheck.sh --nodetype gateway --redis-host redis.example.com
./aap26-healthcheck.sh --nodetype all --db-host db.example.com --redis-host 10.0.0.30:6379
```

## Network listener validation

Derived from the AAP 2.6 "Network ports and protocols" table. Only the
**destination** side (a local listener) is verifiable from the node itself;
outbound/source flows (e.g. node → external DB) need a reachability test with a
target host. Listeners are checked with `ss`.

| Node type | Required (FAIL if missing) | Optional (WARN if missing) |
|---|---|---|
| gateway | 443, 8446 | — |
| controller | 8443 | 8080 |
| hub | 8444 | 8081 |
| eda | 8445 | 8082 |
| execution | — | — |
| all | 443, 8443, 8444, 8445, 8446 | 8080, 8081, 8082 |

The component ports are the configurable `*_nginx_http_port` /
`*_nginx_https_port` inventory values; adjust the numbers in `check_ports` if
you've overridden them. HTTPS ports are treated as required; the paired HTTP
ports are optional (they are typically redirects and may be disabled).

Shared infrastructure ports are checked only when the relevant container is
local, so split / external-DB topologies don't produce false failures:

- **PostgreSQL 5432** — controller, gateway, hub, eda, all
- **Redis 6379** — gateway, eda, all
- **Redis cluster bus 16379** — informational; only present on a clustered
  (multi-node HA) Redis

## Output and exit codes

Every check prints one of:

- `PASS` — healthy
- `WARN` — worth investigating, not necessarily broken
- `FAIL` — a real problem
- `INFO` — context, or a check that was skipped (e.g. no permission)

The run ends with a summary line counting each, plus an overall verdict.

| Exit code | Meaning |
|---|---|
| `0` | No FAIL checks (may include warnings). |
| `1` | One or more FAIL checks. |
| `2` | Bad invocation (unknown/missing argument, unreadable token file). |

This makes it safe to drop into cron, a systemd timer, or a monitoring wrapper:

```bash
./aap26-healthcheck.sh --nodetype all --no-color >> /var/log/aap-health.log 2>&1 || \
  echo "AAP health check FAILED on $(hostname)" | mail -s "AAP health" ops@example.com
```

## Troubleshooting the checks themselves

- **"`systemctl --user` may misbehave" / no failed-unit data** — you're not in a
  proper login session. Re-enter as the install user with `su - <user>` or
  `machinectl shell <user>@`.
- **SELinux denial scan skipped** — the rootless install user usually can't read
  `/var/log/audit/audit.log`. Run that node's check under an account with audit
  or `systemd-journal` group access if you want the scan to run.
- **Infra port shows WARN despite a healthy DB/Redis** — the container may bind
  pod-internally rather than publishing to the host. The dedicated PostgreSQL
  (`pg_isready`) and Redis presence checks are the authoritative health signals.
- **"no X container matched"** — container naming differs from the patterns;
  tighten the regex in `find_container` / `find_containers`.

## Customizing

The script is plain bash with small, single-purpose functions. Common tweaks:

- **Different NGINX ports** → edit the port lists in `check_ports`.
- **External database node** → use `--external-db` (or `--db-host HOST[:PORT]`);
  the `postgresql_admin_password` requirement is dropped automatically.
- **External Redis** → use `--external-redis` (or `--redis-host HOST[:PORT]`).
- **Different container names** → adjust the `find_container` patterns in the
  relevant role function.
- **EDA colocated on the controller** → add `SECRETS_EDA` to the `controller`
  branch of `validate_secrets`.
