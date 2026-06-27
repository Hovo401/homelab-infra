# deploy-diotek/

Ansible provisioning for `diotek.pp.ua`: a React SPA + Node/pm2 backend +
PostgreSQL + MinIO. One command turns a blank Ubuntu host into a working
server:

- Node.js (NodeSource) + pm2 with systemd boot resurrection
- PostgreSQL (native apt package), dev-tuned for a small/shared box
- MinIO (native binary + systemd), single-drive mode, bound to `127.0.0.1`
- nginx from nginx.org: TLS vhost for the SPA + `/api/`, and a second TLS
  vhost for `minio.diotek.pp.ua` (S3 API + web console, IP-restricted)
- Let's Encrypt certs via webroot for both vhosts, auto-renewal + reload hook

Target host lives in `inventory.ini`, values in `group_vars/all.yml`.

## Independent from `deploy/`

This folder is a **separate, self-contained Ansible project** from `../deploy/`
(which provisions `primess.diotek.pp.ua` for the unrelated paidemail app). They
currently share one physical server as a temporary cost-saving measure, but
neither one assumes the other exists:

- Separate `inventory.ini`, `group_vars`, roles — no shared variables.
- The `firewall` role here only *adds* ufw rules (SSH/80/443/Postgres-by-CIDR);
  it never resets ufw or touches rules the other project added.
- The `webserver` role here only manages its own `/etc/nginx/conf.d/<domain>.conf`
  files; it never touches nginx.conf or the other project's vhost files.

Because of that, running `deploy/site.yml` and `deploy-diotek/site.yml` against
the same host works in either order, repeatedly. When a dedicated server is
available for this app, copy this folder there, point `inventory.ini` at the
new host, and run `site.yml` — nothing else changes.

## Layout

```
ansible.cfg            inventory, roles path, become defaults
inventory.ini           target host(s)
group_vars/all.yml      domain, app_dir, static dir, backend port, db/minio settings
site.yml                entrypoint
roles/
  firewall/             ufw default-deny + 22/80/443 + 5432 (CIDR-restricted)
  nodejs/                Node.js + pm2 + pm2 systemd startup
  postgresql/            apt install, dev-tuned conf.d drop-in, pg_hba, db+role
  minio/                 binary + systemd unit, bound to 127.0.0.1 only
  webserver/             nginx.org + 2 vhosts (app domain, minio subdomain) + certbot
  app/                   app dirs + pm2 ecosystem config
```

## Prerequisites

- Ansible on the control machine, plus collections:
  `ansible-galaxy collection install -r requirements.yml`
  (or use `run.ps1`, which runs a pinned `willhallonline/ansible` image)
- SSH access to the target as the user in `inventory.ini`, with sudo
- DNS for `domain` **and** `minio_domain` already point at the server
  (certbot needs `:80` reachable on both names)

## Usage

```bash
cd deploy-diotek

# dry run
ansible-playbook site.yml --ask-become-pass --check --diff \
  --extra-vars "db_password=CHANGE_ME minio_root_password=CHANGE_ME"

# apply
ansible-playbook site.yml --ask-become-pass \
  --extra-vars "db_password=CHANGE_ME minio_root_password=CHANGE_ME"

# overriding minio_scoped_users (a list) needs JSON, not key=value:
ansible-playbook site.yml --ask-become-pass \
  --extra-vars '{"minio_scoped_users": [{"name": "diotek-app", "password": "CHANGE_ME", "buckets": ["diotek"]}]}'

# one layer
ansible-playbook site.yml --ask-become-pass --tags postgresql
```

Prefer an ansible-vault file over `--extra-vars` on a shared shell history;
either way, **never** commit real values for `db_password` /
`minio_root_password` — they default to empty strings in `group_vars/all.yml`.

## Variables

| Variable               | Where                     | Default                    |
|-------------------------|---------------------------|-----------------------------|
| `domain`                | group_vars/all.yml        | `diotek.pp.ua`              |
| `minio_domain`          | group_vars/all.yml        | `minio.diotek.pp.ua`        |
| `app_dir`               | group_vars/all.yml        | `/opt/diotek`                |
| `frontend_static_dir`   | group_vars/all.yml        | `/var/www/diotek`            |
| `backend_port`          | group_vars/all.yml        | `8001`                       |
| `db_name` / `db_user`   | group_vars/all.yml        | `diotek`                     |
| `db_password`           | group_vars/all.yml        | `""` — pass via `--extra-vars`/vault |
| `minio_root_user`       | group_vars/all.yml        | `diotek-admin`               |
| `minio_root_password`   | group_vars/all.yml        | `""` — pass via `--extra-vars`/vault |
| `minio_port` / `minio_console_port` | group_vars/all.yml | `9000` / `9001` (loopback only) |
| `admin_allowed_cidrs`   | group_vars/all.yml        | `["0.0.0.0/0"]` — open to all; restrict to specific CIDRs to lock down Postgres/MinIO |
| `minio_public_buckets`  | roles/minio/defaults      | `["diotek"]`                 |
| `minio_scoped_users`    | group_vars/all.yml        | per-user MinIO accounts, scoped by `mc admin policy` to only their `buckets` |
| `node_major`            | roles/nodejs/defaults     | `"24"`                       |
| `pm2_version`           | roles/nodejs/defaults     | `"5.4.3"`                    |
| `ssh_port`              | roles/firewall/defaults   | `22`                         |
| `nginx_repo_branch`     | roles/webserver/defaults | `""` (stable)                |
| `certbot_webroot`       | roles/webserver/defaults | `/var/www/certbot`           |
| `letsencrypt_email`     | roles/webserver/defaults | `""` (no email)              |
| `postgres_shared_buffers` / `postgres_max_connections` | roles/postgresql/defaults | `32MB` / `20` |

## Network exposure

Only three things are reachable from outside this host:

- **22/tcp** — SSH
- **80/443/tcp** — nginx (both vhosts terminate TLS here)
- **5432/tcp** — PostgreSQL, but only from `admin_allowed_cidrs` (ufw rule)

MinIO (`9000`/`9001`) is **not** opened in ufw at all — it's bound to
`127.0.0.1` and reached only via the `minio.diotek.pp.ua` nginx vhost, which
itself enforces `admin_allowed_cidrs` with nginx `allow`/`deny`. The Node
backend talks to both Postgres and MinIO over `127.0.0.1` directly, never
through the public hostnames.

`admin_allowed_cidrs` defaults to `["0.0.0.0/0"]` — Postgres on 5432 and the
MinIO S3 API/console are reachable from **any** IP with valid credentials.
This was opened intentionally for convenience; set it to specific CIDRs
(e.g. `["203.0.113.5/32"]`) to lock both back down to an admin allowlist.

### MinIO bucket defaults to public

Newer MinIO Community Edition console builds removed the Access Policy UI
control entirely (no Private/Public toggle), so the `minio` role sets it via
the `mc` CLI instead — see `roles/minio/tasks/main.yml`. On every run it:

- installs `mc` to `/usr/local/bin/mc` and configures alias `local`
- creates each bucket in `minio_public_buckets` (default `["diotek"]`) if it
  doesn't exist
- runs `mc anonymous set public local/<bucket>` for each — **anonymous clients
  can both read and write to these buckets**, not just read

To change this:

- different policy: SSH in and run `mc anonymous set private|download local/<bucket>`
  directly (the role won't fight you until the next playbook run re-applies `public`)
- different buckets: override `minio_public_buckets` in `group_vars/all.yml`
- stop managing it here: remove the last two tasks from `roles/minio/tasks/main.yml`

## Dev-mode tuning — revisit before real load

PostgreSQL and MinIO are tuned for coexisting cheaply on a small, shared box:
`shared_buffers`/`max_connections` are deliberately low, and MinIO runs
single-drive (no erasure coding/replication). Before this app sees real
traffic, or once it gets a dedicated server:

- Raise `postgres_shared_buffers`/`postgres_max_connections` to match
  available RAM and expected concurrency.
- Consider whether `admin_allowed_cidrs` should still be open at all once the
  app has its own server — for a single-tenant box, binding everything to
  `127.0.0.1` and dropping the ufw/nginx allowlists entirely is simpler and
  more secure than IP-restricting.
- Consider multi-drive MinIO (erasure coding) for durability.

## Not handled here

Shipping application code. After build artifacts are in place
(`{{ app_dir }}/backend/dist`, built SPA in `{{ frontend_static_dir }}`, and
secrets — `DATABASE_URL`, `MINIO_*` — written to `{{ app_dir }}/shared/.env` by
CI, same convention as `../deploy/`, see `../docs/ENV.md`), start the backend
once:

```bash
pm2 start /opt/diotek/ecosystem.config.js && pm2 save
```

Later ecosystem-config changes are reloaded by the `app` role.
