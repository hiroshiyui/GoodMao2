# 21. Erlang distribution on loopback, with a cookie per server

- **Status:** Accepted
- **Date:** 2026-09-18
- **Deciders:** GoodMao maintainers

## Context

GoodMao2 shares its production host with Baudrate ([`../deployment.md`](../deployment.md)),
each app running as its own system account. Every host-level identifier was made distinct —
port, database role, deploy tree, unit, service user — but one was not: the Erlang
distribution the release starts by default.

A release joins the distribution with the cookie `mix release` writes into
`releases/COOKIE`, and the cookie is the **only** thing distribution checks. Anyone who
connects with it can run arbitrary code inside the node — as `goodmao`, with the database
credentials, `SECRET_KEY_BASE`, the TOTP and VAPID keys and every pet's records. On the
production host that file was mode `0644` under `/opt/goodmao2` (`0755`), so the
`baudrate` account — or anyone who compromised Baudrate — could read it, and the reverse
held for Baudrate's cookie. The node also used the default short name and listened on every
interface (the firewall kept it off the internet, but not off the host).

Binding to `127.0.0.1` alone does not separate two accounts on one host: every local account
reaches loopback. Only a cookie the other account cannot read does.

## Decision

- The release runs Erlang distribution **only with a cookie the server provides**:
  `rel/env.sh.eex` refuses `start`, `start_iex`, `daemon`, `daemon_iex`, `remote`, `rpc`,
  `restart`, `stop` and `pid` when `RELEASE_COOKIE` is unset or equals `releases/COOKIE`.
  `eval` and `version` start no distribution and need none, so `bin/migrate` is unaffected.
  `RELEASE_DISTRIBUTION=none` also bypasses the check, because it opens no port.
- **Ansible generates the cookie on the server, once** (`env/release_cookie`, `0600`, in the
  `0700` `env/` directory owned by `goodmao`) and writes it into `goodmao2.env` as
  `RELEASE_COOKIE`. It is never copied to the control machine's disk or into git, and
  redeploys keep it, so `ExecStop` (`bin/goodmao2 stop`) can always reach the running node.
- **Distribution listens on 127.0.0.1 only**: the node is `goodmao2@127.0.0.1`
  (`RELEASE_DISTRIBUTION=name`), `vm.args` and `remote.vm.args` set
  `-kernel inet_dist_use_interface {127,0,0,1}`, and an epmd the release starts binds
  loopback (`ERL_EPMD_ADDRESS`).

`test/goodmao2/release_distribution_test.exs` renders `env.sh.eex` and sources it, and checks
both `vm.args` files.

## Consequences

- A remote console needs the environment file: as root,
  `sudo -u goodmao sh -c 'set -a; . /opt/goodmao2/env/goodmao2.env; exec /opt/goodmao2/current/bin/goodmao2 remote'`.
- A node started by hand without `RELEASE_COOKIE` fails at once with an explanation instead
  of starting on a cookie other accounts can read.
- The node name changes from `goodmao2@<hostname>` to `goodmao2@127.0.0.1`. On the first
  deploy with this change `ExecStop` cannot reach the old node (different name and cookie),
  so systemd falls back to `SIGTERM`, which the BEAM also handles as a clean shutdown.
- Clustering GoodMao2 across hosts is ruled out while this stands; that would need TLS
  distribution and a new ADR.
- **epmd is shared with Baudrate**: whichever app starts first runs it, and
  `ERL_EPMD_ADDRESS` only affects an epmd this release starts. epmd only maps node names to
  ports, so sharing it is harmless once both apps use a secret cookie on loopback. Baudrate
  made the same change (its ADR 0036).
- Releases older than this change, kept for rollback, still read `RELEASE_COOKIE` from the
  environment file, so they also run with the server's cookie, but on every interface.

## Alternatives considered

- **`chmod 600 releases/COOKIE` after each deploy** — fixes the file but not the model: every
  build writes a new world-readable cookie, and a missed step silently reopens the hole.
- **`RELEASE_DISTRIBUTION=none`** — strongest (no port at all), but `bin/goodmao2 stop`,
  `remote` and `rpc` all need distribution, and the systemd unit's `ExecStop` uses `stop`.
- **A cookie in the SOPS secrets** — works, but puts a host-local credential on every
  operator's disk and in git history for no benefit; the server can generate its own.
- **Loopback binding alone** — does not keep out another account on the same host.
