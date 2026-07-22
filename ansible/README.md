# GoodMao2 — Ansible Playbooks

Ansible automation for provisioning and deploying GoodMao2. Mirrors the sibling
**Baudrate** deploy, so the two apps co-host on one host with every identifier
kept distinct (see [`../doc/deployment.md`](../doc/deployment.md) for the
co-hosting model and the collision table).

## Prerequisites

- **Ansible 2.14+** on the control machine
- **[SOPS](https://github.com/getsops/sops)** for secrets management
- **GPG key** for encrypting/decrypting secrets
- **Ansible collections:**
  ```bash
  ansible-galaxy collection install community.general community.postgresql community.sops
  ```
- **Target server:** Debian 12 (Bookworm) with SSH access
- **DNS:** domain pointed at the server's IP (required for Let's Encrypt)
- **Amazon SES:** a verified sender identity + an IAM credential with
  `ses:SendRawEmail` (a fresh SES account is sandboxed — request production
  access before onboarding real users)

## Quick Start

1. **Configure inventory** — edit `inventory/hosts.yml` with your server.

2. **Configure SOPS** — edit `.sops.yaml` with your GPG fingerprint:
   ```bash
   gpg --list-keys --keyid-format long   # find your fingerprint
   ```
   If you already operate Baudrate, reuse the same GPG key. For multiple
   operators, list all fingerprints comma-separated.

3. **Set up secrets:**
   ```bash
   cd ansible
   cp inventory/group_vars/all.sops.yml.example inventory/group_vars/all.sops.yml
   sops inventory/group_vars/all.sops.yml
   ```
   Set `postgres_db_password`, `secret_key_base`, `aws_ses_access_key_id`, and
   `aws_ses_secret_access_key`. SOPS encrypts on save. (If you skip the DB
   password / secret key base, the playbooks auto-generate and pause so you can
   save them — but the SES credentials must be provided by hand.)

4. **Provision, then deploy:**
   ```bash
   ansible-playbook playbooks/setup-server.yml
   ansible-playbook playbooks/deploy-goodmao2.yml
   ```
   No `--ask-vault-pass` — SOPS decrypts via your GPG key. You'll be prompted for
   the site domain (or set `GOODMAO_DOMAIN`), the Let's Encrypt email (or
   `GOODMAO_CERTBOT_EMAIL`), and the release tag.

## What `setup-server.yml` Does

Provisions infrastructure only — does **not** deploy the application.

| Role | Tag | Purpose |
|------|-----|---------|
| `common` | `common` | System packages incl. **ffmpeg** (runtime media purification), `goodmao` user, UFW firewall, SSH hardening, fail2ban, NTP |
| `postgresql` | `postgresql` | PostgreSQL 15, `goodmao` role + `goodmao2_prod` database, scram-sha-256 local auth |
| `elixir` | `elixir` | asdf + Erlang 28.3.1 + Elixir 1.19.5 + Hex/Rebar |
| `rust` | `rust` | rustup (minimal profile) for the `goodmao2_native` Rustler NIF |
| `nginx` | `nginx` | nginx, Let's Encrypt SSL via certbot, reverse-proxy vhost keyed on `server_name` |

The firewall opens only 80/443 and SSH — the app's `PORT` (5000) stays on
loopback, which is what lets GoodMao2 and Baudrate share a host safely.

## Deploying GoodMao2

```bash
ansible-playbook playbooks/deploy-goodmao2.yml
```

Prompts: **domain** (or `GOODMAO_DOMAIN`), **release tag** (a git tag like
`v1.0.0`), **git repo** (defaults to the upstream). The SES credentials must
already be in your SOPS secrets — the playbook asserts they exist, because the
app fails to boot without them.

### What `deploy-goodmao2.yml` Does

All tasks run as the `goodmao` system user by default; only systemd operations
escalate to root.

| Phase | Description |
|-------|-------------|
| Pre-flight | Verify `goodmao` user + asdf; warn if deploying an older version |
| Directories | Create `releases/`, `shared/media/` (MEDIA_STORAGE_DIR), `env/` |
| Source | Clone repo and check out the prompted release tag |
| Build | `mix deps.get --only prod` → `compile` → `assets.deploy` → clean stale rel → `mix release` |
| Install | Copy release to `releases/<timestamp>/` |
| Env file | Template `goodmao2.env` (DB, secret key base, media dir, SES mailer, …) |
| Systemd | Install and enable `goodmao2.service` |
| Migrate | Source the env file, run `bin/migrate` from the new release |
| Activate | Atomic symlink swap: `current` → new release |
| Health check | Poll `/health` until 200 (up to 60 seconds) |
| Cleanup | Remove old releases, keep `keep_releases` most recent (default 5) |

### Server Directory Layout

```
/opt/goodmao2/
  src/                                        # Git checkout (build workspace)
  releases/
    20260722_150000/                          # Timestamped release
      bin/server, bin/migrate, bin/goodmao2
  current -> releases/20260722_150000         # Symlink to active release
  static  -> current/lib/goodmao2-*/priv/static   # Stable path for nginx /assets
  shared/
    media/                                    # MEDIA_STORAGE_DIR — app-served, never static
  env/
    goodmao2.env                              # EnvironmentFile for systemd (mode 0600)
```

### Rollback

Re-deploy with an older tag; the playbook warns and asks for confirmation:

```bash
ansible-playbook playbooks/deploy-goodmao2.yml -e release_tag=v1.0.0
```

**Note:** database migrations are **not** auto-rolled-back.

## Selective Execution & Verification

```bash
ansible-playbook playbooks/setup-server.yml --tags nginx        # one role
ansible-playbook playbooks/setup-server.yml --syntax-check      # no server needed
ansible-playbook playbooks/deploy-goodmao2.yml --check --diff   # dry run
```

## Secrets Management

Secrets are managed with [SOPS](https://github.com/getsops/sops), encrypted with
your OpenPGP key — no shared passphrase. The `community.sops.sops` vars plugin
(enabled in `ansible.cfg`) auto-decrypts `*.sops.yml` in `group_vars/`.

```bash
sops inventory/group_vars/all.sops.yml                 # edit
sops updatekeys inventory/group_vars/all.sops.yml      # after adding an operator to .sops.yaml
```

| Secret (in `all.sops.yml`) | Purpose |
|----------------------------|---------|
| `postgres_db_password` | GoodMao2's DB role password |
| `secret_key_base` | Phoenix cookie/session signing key |
| `aws_ses_access_key_id` / `aws_ses_secret_access_key` | SES IAM credential (`ses:SendRawEmail`) |

Non-secret knobs live in `inventory/group_vars/all.yml` (`app_port`,
`aws_ses_region`, `mailer_from_name`, versions, …). `mailer_from_email` defaults
to `no-reply@<domain>`; override it (and the optional `site_owner_email`) in
`inventory/group_vars/production.yml`.

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `GOODMAO_DOMAIN` | Default for the domain prompt (both playbooks) |
| `GOODMAO_CERTBOT_EMAIL` | Default for the certbot email prompt (setup-server) |
