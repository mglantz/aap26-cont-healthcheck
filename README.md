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
./aap26-healthcheck.sh --nodetype <GROUP|aio> [options]
```

### Options


| Option                     | Description                                                                                                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--nodetype TYPE`          | **Required.** AAP 2.6 installer inventory group name for this host, or `aio` for all-in-one (see below).                                                                    |
| `--api-host HOST`          | Base host for API probes. Default `https://localhost`.                                                                                                                      |
| `--token TOKEN`            | Bearer token for authenticated API calls. Visible in `ps`/history — prefer the options below.                                                                               |
| `--token-file FILE`        | Read the bearer token from the first line of `FILE`.                                                                                                                        |
| `--external-db`            | The database is external/managed, not a local container. Skips the `postgresql_admin_password` secret requirement. Auto-detected when no local postgres container is found. |
| `--db-host HOST[:PORT]`    | External database host (implies `--external-db`). Enables a TCP reachability test to the DB; port defaults to 5432.                                                         |
| `--external-redis`         | Redis is external/managed, not a local container. Auto-detected when no local redis container is found.                                                                     |
| `--redis-host HOST[:PORT]` | External Redis host (implies `--external-redis`). Enables a TCP reachability test to Redis; port defaults to 6379.                                                          |
| `--log-lines N`            | Lines of container log to scan for errors. Default `200`.                                                                                                                   |
| `--verbose`, `-v`          | Show extra detail (full container list, log excerpts, denial samples).                                                                                                      |
| `--no-color`               | Disable colored output (useful for cron/CI logs).                                                                                                                           |
| `--help`, `-h`             | Show usage.                                                                                                                                                                 |


### Node types

Use the **AAP 2.6 installer inventory group name** for the role running on the
node, or `aio` when every component is colocated on a single host.


| Value                                       | Node                                                        |
| ------------------------------------------- | ----------------------------------------------------------- |
| `automationgateway`                         | Platform Gateway (+ Envoy proxy)                            |
| `automationcontroller`                      | Automation Controller                                       |
| `automationhub`                             | Automation Hub (Pulp)                                       |
| `automationeda` / `automationedacontroller` | Event-Driven Ansible                                        |
| `execution_nodes`                           | Execution node (Receptor)                                   |
| `aio`                                       | All-in-one / single-node deployment (runs every role check) |


### Examples

```bash
# Single-node / all-in-one box
./aap26-healthcheck.sh --nodetype aio --verbose

# A dedicated gateway node
./aap26-healthcheck.sh --nodetype automationgateway

# Controller node, authenticated probes via a token file
./aap26-healthcheck.sh --nodetype automationcontroller --token-file ~/.aap/token

# Token via environment variable, custom API host
AAP_TOKEN="$(cat ~/.aap/token)" \
  ./aap26-healthcheck.sh --nodetype automationcontroller --api-host https://aap26m.sudo.net
```

## Ansible playbook

`aap26-healthcheck.yml` runs the healthcheck across every host in your
**AAP installation inventory**, then writes a consolidated report under
`reports/` on the control node.

### Requirements

- Ansible 2.14+ (uses the `ansible.builtin.script` module).
- Your AAP 2.6 installer `inventory` file.
- SSH (or other configured transport) access to each node **as the container
install user** — the same user used by the AAP installer.
- The **Ansible Vault password** used to encrypt `aap_api_token` in the playbook
(see below).

### API token (Ansible Vault)

The gateway bearer token is defined as `aap_api_token` in the playbook `vars`
section, encrypted with **Ansible Vault**. Ansible decrypts it at runtime and
passes it to each node as `$AAP_TOKEN` for authenticated API probes.

You do **not** need to pass the token on the command line. Provide the vault
password when you run the playbook, for example:

```bash
ansible-playbook -i inventory aap26-healthcheck.yml \
  -e aap_aio_deployment=true \
  --ask-vault-pass
```

Or point at a vault password file:

```bash
ansible-playbook -i inventory aap26-healthcheck.yml \
  -e aap_aio_deployment=true \
  --vault-password-file ~/.aap/vault-pass
```

To replace the token, edit the encrypted value in the playbook:

```bash
ansible-vault edit aap26-healthcheck.yml
```

Or generate a new inline vault string and paste it over `aap_api_token`:

```bash
ansible-vault encrypt_string 'your-gateway-token' --name 'aap_api_token'
```

You can still override the token for a one-off run with `-e aap_api_token=...`
without changing the playbook.

### Required extra-vars


| Variable             | Description                                                               |
| -------------------- | ------------------------------------------------------------------------- |
| `aap_aio_deployment` | `true` for an all-in-one deployment; `false` for enterprise / multi-node. |


### Optional extra-vars


| Variable                     | Description                                                    |
| ---------------------------- | -------------------------------------------------------------- |
| `aap_healthcheck_extra_args` | Extra arguments forwarded to the script, e.g. `["--verbose"]`. |
| `aap_api_token`              | Override the vault-encrypted token from the playbook.          |


### Examples

All-in-one deployment:

```bash
ansible-playbook -i inventory aap26-healthcheck.yml \
  -e aap_aio_deployment=true \
  --ask-vault-pass
```

Enterprise / multi-node deployment:

```bash
ansible-playbook -i inventory aap26-healthcheck.yml \
  -e aap_aio_deployment=false \
  --ask-vault-pass
```

With verbose script output:

```bash
ansible-playbook -i inventory aap26-healthcheck.yml \
  -e aap_aio_deployment=true \
  -e 'aap_healthcheck_extra_args=["--verbose"]' \
  --ask-vault-pass
```

### How it works

- **Enterprise** (`aap_aio_deployment=false`): each host is checked with
`--nodetype` set to its primary inventory group.
- **AIO** (`aap_aio_deployment=true`): each host is checked with
`--nodetype aio`.
- The vault-encrypted `aap_api_token` is exported as `$AAP_TOKEN` on each node
during the script run.
- Per-node failures are collected (`ignore_errors: true` on the script task) so
every node is checked before the playbook exits.
- A timestamped report is written to
`reports/aap26-healthcheck-report-<timestamp>.txt`. The playbook fails at the
end if any node reported failures — review the report file for details.

## Authentication

Many of the API endpoints require authentication. A gateway-issued bearer token is required and can be inputted in 3 ways:

1. `--token TOKEN`
2. `--token-file FILE`
3. `$AAP_TOKEN` environment variable

The token is never printed; preflight only reports its source. Passing it on the command line is not recommended as it will be visible in the process list and shell history.

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
name (FAIL on a short name, IP address, or `localhost`*), with best-effort
checks that `hostname -f` and forward resolution agree. AAP requires every
node to have a resolvable FQDN; run the script on each node to cover them all.
- **Time synchronization** — clock skew silently breaks TLS validation, OAuth
tokens, and the receptor mesh, so a node that isn't NTP-synced is flagged
(via `timedatectl`/`chronyc`).
- **User namespace mappings** — verifies the install user has `/etc/subuid` and
`/etc/subgid` ranges; without them rootless containers and EEs can't start.
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

In addition to the per-role container/API checks, each node validates its TLS
certificate expiry (WARN within 30 days, FAIL if expired — important because the
API probes use `-k`) and that its database migrations are fully applied (a
silent post-upgrade breakage). Specifically:

- **gateway** — gateway and Envoy/proxy containers; gateway API and login page
reachability; an explicit scan for Fernet `InvalidToken` (the secret-key
mismatch failure mode); **routing checks that probe the controller, hub, and
EDA backends *through* the gateway** (confirming it actually proxies); Redis;
PostgreSQL.
- **controller** — web/task containers; `/api/controller/v2/ping/`; dispatcher
activity; the metrics endpoint; **instance and capacity health** (with a token:
confirms this node is enabled with capacity > 0, and reports every mesh node's
health — the control-plane's view of the receptor mesh); Redis; PostgreSQL;
Receptor container.
- **hub** — Pulp api/content/worker containers; the unauthenticated Pulp status
endpoint (parsed for DB-connected + online worker count); Redis; PostgreSQL.
- **eda** — EDA api/worker containers; the EDA API; Redis; PostgreSQL.
- **execution** — Receptor container; a receptor-log scan for mesh dialing/TLS
failures; execution environment images present; and a warning if control-plane
containers are running where they shouldn't be.

The instance/capacity check needs a token (`--token`) to read
`/api/controller/v2/instances/`; without one it reports an INFO rather than
failing. Migration checks try the component's management command
(`awx-manage`, `pulpcore-manager`, `aap-gateway-manage`, `aap-eda-manage`) and
skip with an INFO if it isn't found rather than failing.

Container discovery is pattern-based off `podman ps`, so it adapts to naming
differences. If a component's container name doesn't match, you'll see a
"no X container matched" warning rather than a silent miss.

## Podman secret validation

Each expected secret is checked with `podman secret exists NAME`; only exit code
0 counts as present, anything else is a FAIL. Secrets are grouped by component
and validated according to node type.


| Group      | Secrets                                                                                                                                                 |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| database   | `postgresql_admin_password`                                                                                                                             |
| gateway    | `gateway_secret_key`, `gateway_db_password`, `gateway_admin_password`, `gateway_redis_url`                                                              |
| controller | `controller_channels`, `controller_resource_server`, `controller_postgres`, `controller_secret_key`                                                     |
| eda        | `eda_resource_server`, `eda_secret_key`, `eda_admin_password`, `eda_db_password`                                                                        |
| hub        | `hub_secret_key`, `hub_collection_signing_passphrase`, `hub_settings`, `hub_database_fields`, `hub_resource_server`, `hub_container_signing_passphrase` |



| Node type                                   | Validated groups                                  |
| ------------------------------------------- | ------------------------------------------------- |
| `automationgateway`                         | database + gateway                                |
| `automationcontroller`                      | database + controller                             |
| `automationhub`                             | database + hub                                    |
| `automationeda` / `automationedacontroller` | database + eda                                    |
| `execution_nodes`                           | none (Receptor uses TLS certs, not these secrets) |
| `aio`                                       | every group                                       |


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
./aap26-healthcheck.sh --nodetype automationcontroller --db-host db.example.com
./aap26-healthcheck.sh --nodetype aio --db-host 10.0.0.20:5432
```

**External / managed Redis:** handled the same way. It's auto-detected when no
local redis container is present (or set `--external-redis`), in which case the
absence is reported as expected (INFO) rather than a warning. Add
`--redis-host HOST[:PORT]` for a TCP reachability test from the node to the
external Redis. There is no Redis equivalent of `postgresql_admin_password` to
skip — `gateway_redis_url` is the connection config and is validated in both
local and external modes.

```bash
./aap26-healthcheck.sh --nodetype automationgateway --redis-host redis.example.com
./aap26-healthcheck.sh --nodetype aio --db-host db.example.com --redis-host 10.0.0.30:6379
```

## Network listener validation

Derived from the AAP 2.6 "Network ports and protocols" table. Only the
**destination** side (a local listener) is verifiable from the node itself;
outbound/source flows (e.g. node → external DB) need a reachability test with a
target host. Listeners are checked with `ss`.


| Node type                                   | Required (FAIL if missing)  | Optional (WARN if missing) |
| ------------------------------------------- | --------------------------- | -------------------------- |
| `automationgateway`                         | 443, 8446                   | —                          |
| `automationcontroller`                      | 8443                        | 8080                       |
| `automationhub`                             | 8444                        | 8081                       |
| `automationeda` / `automationedacontroller` | 8445                        | 8082                       |
| `execution_nodes`                           | —                           | —                          |
| `aio`                                       | 443, 8443, 8444, 8445, 8446 | 8080, 8081, 8082           |


The component ports are the configurable `*_nginx_http_port` /
`*_nginx_https_port` inventory values; adjust the numbers in `check_ports` if
you've overridden them. HTTPS ports are treated as required; the paired HTTP
ports are optional (they are typically redirects and may be disabled).

Shared infrastructure ports are checked only when the relevant container is
local, so split / external-DB topologies don't produce false failures:

- **PostgreSQL 5432** — automationcontroller, automationgateway, automationhub, automationeda, aio
- **Redis 6379** — automationgateway, automationeda, aio
- **Redis cluster bus 16379** — informational; only present on a clustered
(multi-node HA) Redis

## Output and exit codes

Every check prints one of:

- `PASS` — healthy
- `WARN` — worth investigating, not necessarily broken
- `FAIL` — a real problem
- `INFO` — context, or a check that was skipped (e.g. no permission)

The run ends with a summary line counting each, plus an overall verdict.


| Exit code | Meaning                                                           |
| --------- | ----------------------------------------------------------------- |
| `0`       | No FAIL checks (may include warnings).                            |
| `1`       | One or more FAIL checks.                                          |
| `2`       | Bad invocation (unknown/missing argument, unreadable token file). |


This makes it safe to drop into cron, a systemd timer, or a monitoring wrapper:

```bash
./aap26-healthcheck.sh --nodetype aio --no-color >> /var/log/aap-health.log 2>&1 || \
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

