# Deployment — co-hosting runbook

How to run GoodMao2 in production **alongside a sibling Phoenix app** (Baudrate) on one
host. GoodMao2 is a plain [`mix release`](https://hexdocs.pm/mix/Mix.Tasks.Release.html)
(Elixir/OTP, no Docker) built **on the server** from a git tag, run under **systemd**, and
fronted by **one nginx** that terminates TLS and routes to each app by hostname. This mirrors
Baudrate's deploy (`/home/yhh/MyProjects/baudrate/ansible/`); the sole rule of co-hosting is
that **every host-level identifier is distinct per app**.

> Status: shipped. This runbook is the hand-operated reference; the same steps are **automated in
> [`../ansible/`](../ansible/)** (`setup-server.yml` + `deploy-goodmao2.yml`, mirroring Baudrate's
> playbook). Read this to understand the model; run the playbook to actually deploy.

## First production go-live checklist

A one-time, ordered checklist for the **first** deploy. Each step links to its detail below or in
[`../ansible/README.md`](../ansible/README.md). Ansible does the on-host work; the items marked
**(you)** are external prerequisites and decisions Ansible can't make for you.

**Ahead of time (lead-time items — start these first):**

- [ ] **(you) Amazon SES production access** — a fresh SES account is *sandboxed* (can only mail
      verified addresses). Verify a sender identity, mint an IAM credential scoped to
      `ses:SendRawEmail`, and **request production access** — approval isn't instant. See
      [Mailer — Amazon SES](#mailer--amazon-ses). Without it, real users can't confirm accounts.
- [ ] **(you) DNS** — point the domain's A/AAAA record at the host **before** provisioning, so
      Let's Encrypt (certbot) can issue the cert.
- [ ] **(you) A host** — Debian 12 with SSH; co-hosts with Baudrate (see [collision surface](#the-collision-surface)).
- [ ] **(you) Control machine** — Ansible 2.14+, SOPS, a GPG key, and the three
      `ansible-galaxy` collections (per [`../ansible/README.md`](../ansible/README.md)).

**Configure & deploy:**

- [ ] **Inventory + secrets** — edit `ansible/inventory/hosts.yml`; set `secret_key_base`,
      `postgres_db_password`, and the two `aws_ses_*` credentials via
      `sops inventory/group_vars/all.sops.yml`. The SES credentials **must** be supplied by hand.
- [ ] **Pin the admin** — set `site_owner_email` in `group_vars/production.yml`. This closes the
      "first registrant wins admin" race (ADR-0016) on a public URL. **Recommended for any real deploy.**
- [ ] **Provision** — `ansible-playbook playbooks/setup-server.yml` (pkgs incl. ffmpeg, PG15,
      asdf/Elixir, rust, nginx+certbot). Dry-run first with `--check --diff`.
- [ ] **Deploy the release** — `ansible-playbook playbooks/deploy-goodmao2.yml`, choosing the git
      tag you cut (e.g. **`v0.2.0`**). Ends by polling `/health` until it returns 200.

**First-boot steps the playbook does not cover (do these manually, once):**

- [ ] **Register the admin** as `site_owner_email`. 2FA is **required for the administrator**
      (ADR-0013), so have an authenticator app (TOTP) *or* a FIDO2 security key ready — you're
      forced through 2FA setup before a session is issued. Confirm the confirmation email arrives via SES.
- [ ] **Generate Web Push VAPID keys** at `/admin/settings` — only if you want push. They live in
      the runtime `Settings` store, **not** env vars; push stays disabled (a valid state) until generated.
- [ ] **Set the system default timezone** at `/admin/settings` (else falls back to `Etc/UTC`, ADR-0018).
- [ ] **Review media upload limits** at `/admin/settings` (`Media.Limits`).

**Before onboarding real users — data safety (not yet automated):**

- [ ] **(you) Postgres backups** — a scheduled `pg_dump`/pgBackRest with off-host retention.
      The Ansible roles provision Postgres but do **not** set up backups.
- [ ] **(you) Media backups** — `MEDIA_STORAGE_DIR` (`/opt/goodmao2/shared/media/`) holds the
      only copy of purified LifeLog media; it survives releases but nothing backs it up.
- [ ] **Confirm your rollback path** — migrations are **not** auto-rolled-back (see [Rollback](#rollback)),
      so a restorable DB backup is your real safety net for a bad migration.

## The collision surface

GoodMao2 and Baudrate ship the **same defaults** (both are `phx.gen.release` Phoenix 1.8 apps
listening on `PORT=4000`, both want a Postgres role/db, a systemd unit, and an nginx vhost), so
co-hosting is entirely a matter of giving GoodMao2 its own value for each. Pick once and keep
them consistent across the env file, the systemd unit, and the nginx upstream:

| Concern              | Baudrate (existing)          | GoodMao2 (choose distinct)                 |
| -------------------- | ---------------------------- | ------------------------------------------ |
| HTTP listen `PORT`   | `4000`                       | `5000`                                     |
| Canonical host       | Baudrate's domain            | GoodMao2's domain (`PHX_HOST`)             |
| Postgres role        | `baudrate`                   | `goodmao`                                  |
| Postgres database    | `baudrate_prod`              | `goodmao2_prod`                            |
| OTP / release name   | `baudrate`                   | `goodmao2`                                 |
| Deploy tree          | `/opt/baudrate`              | `/opt/goodmao2`                            |
| systemd unit         | `baudrate.service`           | `goodmao2.service`                         |
| Service user         | `baudrate`                   | `goodmao`                                  |
| nginx `server_name`  | Baudrate's domain            | GoodMao2's domain → upstream `127.0.0.1:5000` |

The `port: 443` in `config/runtime.exs` is only the **canonical-URL** host used to generate
`https://…` links — **not** a listener. The app listens plain HTTP on `PORT`, bound to all
interfaces, and nginx is the only thing terminating TLS.

## Host prerequisites

Provisioned once and **shared** by both apps (Baudrate's `setup-server.yml` already installs
most of these — GoodMao2 adds only ffmpeg):

- **Debian 12** (or similar), a non-login **service user** `goodmao`.
- **asdf** toolchain pinned to GoodMao2's `.tool-versions`: **Erlang 28.3.1**, **Elixir 1.19.5**.
- **Rust toolchain** — GoodMao2 builds a Rustler NIF (`native/goodmao2_native`), pinned by
  `rust-toolchain.toml`. The build host must have `rustup`.
- **PostgreSQL 15**, reachable on `localhost` (TCP or unix socket).
- **ffmpeg + ffprobe** on `PATH` — **required at runtime**, not just build: media purification
  (ADR-0005) shells out to them in the `Media.PurifyWorker`. This is GoodMao2-specific; Baudrate
  does not need it.
- **nginx** with a TLS certificate (Let's Encrypt) for GoodMao2's hostname.

Run `mix goodmao.doctor` (with `MIX_ENV=prod`) as a preflight — it checks the toolchain vs
`.tool-versions`, Postgres reachability + `CREATEDB`, fetched deps, and required prod secrets.

## Postgres — a dedicated role + database

Give GoodMao2 its own role and database, isolated from Baudrate's:

```sql
CREATE ROLE goodmao WITH LOGIN PASSWORD '<generated>' CREATEDB;
CREATE DATABASE goodmao2_prod OWNER goodmao ENCODING 'UTF8';
```

Connection is local, so TLS to Postgres is off: `config/runtime.exs` leaves `Repo`'s `ssl:`
commented out and reads no `DATABASE_SSL` var — the `DATABASE_URL` below connects without SSL,
which is correct for a `localhost` peer. (If you ever move Postgres off-box, add `ssl: true`
to the `Repo` config.)

## The env file

Written to `/opt/goodmao2/env/goodmao2.env`, mode `0600`, owned by `goodmao`, and referenced by
the systemd unit's `EnvironmentFile=`. Every value is read at boot by `config/runtime.exs`:

```sh
# --- server ---
PHX_SERVER=true
PORT=5000                       # DISTINCT from Baudrate's 4000
PHX_HOST=goodmao.tw             # canonical host; also the WebAuthn RP id/origin (ADR-0013)
SECRET_KEY_BASE=<mix phx.gen.secret>
POOL_SIZE=10

# --- database (distinct role + db) ---
DATABASE_URL=ecto://goodmao:<pw>@localhost/goodmao2_prod

# --- media storage (ADR-0005): writable, backed-up, OUTSIDE any served path ---
MEDIA_STORAGE_DIR=/opt/goodmao2/shared/media

# --- mailer: Amazon SES (see below) ---
AWS_SES_REGION=us-east-1
AWS_SES_ACCESS_KEY_ID=<iam key with ses:SendRawEmail>
AWS_SES_SECRET_ACCESS_KEY=<iam secret>
MAILER_FROM_EMAIL=no-reply@goodmao.tw   # MUST be SES-verified
MAILER_FROM_NAME=GoodMao

# --- optional ---
GOODMAO_SITE_OWNER_EMAIL=you@example.com     # pin the bootstrap admin (closes the first-user race)
# ECTO_IPV6=true                             # only if the DB host is IPv6-only
# DNS_CLUSTER_QUERY=...                       # single node ⇒ leave unset
```

`config/runtime.exs` **fails fast** (raises at boot) if `DATABASE_URL`, `SECRET_KEY_BASE`,
`MEDIA_STORAGE_DIR`, the three `AWS_SES_*` vars, or `MAILER_FROM_EMAIL` are missing — a public
deploy that can't reach its DB, store media, or send auth mail is broken, so it refuses to start.

### Mailer — Amazon SES

Auth emails (registration confirmation, magic-link login, email-change) go out through **Amazon
SES** via Swoosh's `Swoosh.Adapters.AmazonSES` (`SendRawEmail` API), which rides the `Req` API
client configured in `config/prod.exs`. The IAM credential needs only `ses:SendRawEmail`. Two
SES gotchas:

- **`MAILER_FROM_EMAIL` must be a verified identity** (address or domain) in that SES account/
  region, or SES rejects the send.
- A brand-new SES account is **sandboxed** — it can only send *to* verified addresses until you
  request production access. Do that before onboarding real users.

## Server directory layout

```
/opt/goodmao2/
├── src/                 # git checkout, built here
├── releases/<ts>/       # one dir per built release (keep the last N)
├── current -> releases/<ts>   # atomic symlink the systemd unit runs from
├── static/              # digested priv/static, served directly by nginx
├── shared/media/        # MEDIA_STORAGE_DIR — survives releases, backed up
└── env/goodmao2.env     # 0600 secrets, EnvironmentFile= for systemd
```

## Build → migrate → activate

All as the `goodmao` user, `MIX_ENV=prod`, from the git tag being released:

```sh
cd /opt/goodmao2/src && git fetch --tags && git checkout <tag>
mix deps.get --only prod
mix compile
mix assets.deploy                 # tailwind/esbuild --minify + phx.digest
rm -rf _build/prod/rel
mix release --overwrite           # -> _build/prod/rel/goodmao2/

# publish the built release
cp -a _build/prod/rel/goodmao2/. /opt/goodmao2/releases/<ts>/
cp -a priv/static/. /opt/goodmao2/static/

# migrate with the NEW release, BEFORE flipping current
env $(cat /opt/goodmao2/env/goodmao2.env | xargs) \
    /opt/goodmao2/releases/<ts>/bin/migrate

# atomic activation + restart
ln -sfn /opt/goodmao2/releases/<ts> /opt/goodmao2/current
sudo systemctl restart goodmao2
```

The release ships `bin/server` (`PHX_SERVER=true exec ./goodmao2 start`) and `bin/migrate`
(`exec ./goodmao2 eval Goodmao2.Release.migrate`) via `rel/overlays/bin/` — the same shape
Baudrate uses. `bin/goodmao2 remote` opens an IEx session against the running node.

## systemd unit

`/etc/systemd/system/goodmao2.service` — note the distinct unit name, user, and `/opt/goodmao2`
paths, and that `MEDIA_STORAGE_DIR` is the one writable path under the sandbox:

```ini
[Unit]
Description=GoodMao2
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=exec
User=goodmao
WorkingDirectory=/opt/goodmao2/current
EnvironmentFile=/opt/goodmao2/env/goodmao2.env
ExecStart=/opt/goodmao2/current/bin/server
ExecStop=/opt/goodmao2/current/bin/goodmao2 stop
Restart=on-failure
RestartSec=5
TimeoutStopSec=35
SyslogIdentifier=goodmao2
# hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/goodmao2/shared/media
ReadOnlyPaths=/opt/goodmao2/current /opt/goodmao2/releases /opt/goodmao2/env
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

## nginx vhost (co-hosting by hostname)

One nginx serves both apps; each gets a `server` block keyed on its `server_name`, proxying to
its own loopback port. GoodMao2's upstream is `127.0.0.1:5000`:

```nginx
upstream goodmao2 { server 127.0.0.1:5000; keepalive 32; }

server {
    listen 80;
    server_name goodmao.tw;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name goodmao.tw;

    ssl_certificate     /etc/letsencrypt/live/goodmao.tw/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/goodmao.tw/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;

    # digested static assets straight from disk
    location /assets/ { alias /opt/goodmao2/static/assets/; expires 1y; access_log off; }

    # LiveView socket — long timeouts
    location /live/websocket {
        proxy_pass http://goodmao2;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
    }

    location / {
        proxy_pass http://goodmao2;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;   # drives force_ssl's rewrite_on
    }
}
```

**Do not serve uploaded media from nginx.** Unlike Baudrate's `/uploads`, GoodMao2's media
objects are opaque, id-keyed, and **authorized per request** (`MediaController`, IDOR-hidden) —
they must flow through the app, never off a static path. Only the digested `/assets/` are
nginx-served. `X-Forwarded-Proto` is required: `config/prod.exs` sets
`force_ssl: [rewrite_on: [:x_forwarded_proto]]`, so nginx must pass it for the HTTPS redirect to
behave behind the proxy.

## Verify

```sh
systemctl status goodmao2
curl -fsS http://127.0.0.1:5000/health      # HealthController -> 200
curl -fsSI https://goodmao.tw/          # through nginx, TLS
```

Then register the first account (or the `GOODMAO_SITE_OWNER_EMAIL` you pinned) — it becomes the
sole admin (ADR-0016) — and confirm the confirmation email arrives via SES.

## Rollback

Re-point `current` at a previous release dir and restart:

```sh
ln -sfn /opt/goodmao2/releases/<older-ts> /opt/goodmao2/current
sudo systemctl restart goodmao2
```

Schema migrations are **not** auto-rolled-back; if a release migrated the DB, roll it back
explicitly with `bin/goodmao2 eval 'Goodmao2.Release.rollback(Goodmao2.Repo, <version>)'`
before serving the older code.
