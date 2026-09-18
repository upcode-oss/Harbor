# Installation & Deployment

## System Requirements

| Requirement | Minimum |
|---|---|
| Operating System | Linux Debian |
| Python | 3.11 or higher |
| Node.js | 20 or higher |
| Docker, K3s, LXC/LXD, ZFS | Selected in an interactive checklist or with installer options |
| OpenSSH server | Always installed and enabled |
| Root Access | Required to run the installer and signed updater |

---

## Quick Installation

Version 0.7.0 begins a completely renamed technical deployment contract. It
does not provide an in-place update or compatibility aliases for installations
from 0.6.x or older. Back up the existing host separately and install 0.7.0
from a clean checkout or on a clean host.

```bash
git clone https://github.com/upcode-at/upcode-harbor.git
cd upcode-harbor
sudo ./install.sh
```

The installer automatically downloads the noVNC submodule at the commit pinned
by your Harbor checkout. No manual submodule initialization is required. Existing
tracked noVNC changes are not overwritten forcibly; use a clean checkout if
validation fails. Source archives must already include noVNC.

The `install.sh` script handles:

- Selecting Docker, K3s, LXC/LXD, and ZFS in a terminal checklist
- Always installing and enabling the OpenSSH server
- Creating dedicated `upcode-harbor` backend/worker and `upcode-harbor-web` accounts
- Installing an immutable root-owned release below `/opt/upcode-harbor/releases`
- Installing locked dependencies with `npm ci` and `requirements.lock`
- Creating separate API, frontend, worker, health, and update systemd units
- Installing a backend-only, allowlisted root helper and sudoers rule
- Exposing loopback-only application ports through an HTTPS nginx proxy
- Running the post-install privilege and health smoke test

After a successful installation, open the URL printed by the installer, usually
`https://SERVER-IP/`. The automatically generated certificate may require a
one-time browser confirmation. Ports `9200` (frontend) and `9500` (API) bind to
loopback intentionally and are only nginx upstreams; they are not remote access
URLs. nginx accepts remote HTTPS connections on port `443`.

To use your own reverse proxy, deselect **Nginx HTTPS Reverse Proxy** in the
checklist or skip its installation and configuration explicitly:

```bash
sudo ./install.sh --profile core --skip-nginx
```

This skips nginx, Certbot, and the local web TLS certificate setup. Frontend
and API remain bound to `127.0.0.1` on ports `9200` and `9500`. Configure an
HTTPS proxy on the same host: route `/` to the frontend, and `/api/` and `/ws/`
to the API with those prefixes stripped. Forward WebSocket upgrade headers.
See `deploy/nginx/upcode-harbor.conf` for the complete routing template.

`--resume` remembers this choice; `--resume --skip-nginx` also skips a previously
failed nginx step. Use `--with-nginx` to override the recorded choice when nginx
and Certbot are installed. Profiles include nginx by default.

Upcode Harbor never creates application login users or assigns their passwords. Sign
in with an existing Linux username and its PAM password. The installer creates
the dedicated `/etc/pam.d/upcode-harbor` service policy, which delegates password and
account checks to Debian's managed `common-auth` and `common-account` stacks.
The unprivileged API passes password input over a pipe to the root-owned,
allowlisted authentication operation; the password never appears in a process
argument or environment variable.
Upcode Harbor permissions
derive from Linux groups such as `sudo`, `docker`, `libvirt`, and `adm`. On a
host configured exclusively for SSH-key authentication, assign a password to
the existing Linux user if that account should also authenticate through the
web login. The `upcode-harbor` and `upcode-harbor-web` accounts created by the installer are
non-login service identities and cannot be used for the web login.

A `401` response from `GET /api/auth/me` before a session exists is expected.
If `POST /api/auth/login` also returns `401`, PAM rejected the Linux account or
password. Confirm that the user exists and has an unlocked password, then check
the PAM code and reason in `/var/log/upcode-harbor/activity.log`. Upcode Harbor never sends
that diagnostic detail to the browser. A journal entry from `unix_chkpwd` with
the `upcode-harbor` service UID and `user unknown` for a real user indicates an old
unprivileged PAM implementation; reinstall the current release so the
root-owned PAM broker and its `pamtester` dependency are deployed.

If a run was interrupted after the immutable release was created, rebuild its
configuration and finish the remaining initialization without reinstalling
packages or overwriting the release:

```bash
sudo ./install.sh --resume
```

The installer generates all node-local key material automatically: the nginx
TLS certificate and private key (unless `--skip-nginx` is selected), the application encryption key, the session
signing secret, and the cluster CA/certificate/private key. A release public key
cannot be generated locally because it must match the external update signer;
signed updates therefore remain disabled unless `--update-public-key` is used.

For a clean restart after a broken installation, use `--reinstall`. The
installer stops Upcode Harbor, moves the existing release, secrets, state, web state,
logs, update trust, and managed system integration files into a mode-`0700`
recovery directory below
`/var/backups/upcode-harbor/`, and then performs a fresh installation with newly
generated local keys:

```bash
sudo ./install.sh --reinstall
```

Run this command from a separate source checkout. It is intentionally rejected
when `install.sh` itself is located below `/opt/upcode-harbor`.

To enable signed updates non-interactively, select a profile and supply the
release public key:

```bash
sudo ./install.sh --profile full \
  --update-public-key /secure/release-public.pem
```

With no component options, an interactive terminal checklist shows Docker,
K3s, LXC/LXD, and ZFS. Use the arrow keys to move, Space to toggle an entry, and
Tab/Enter to confirm. The installer adds `whiptail` automatically if the
checklist program is missing. Available automation profiles are `full`, `core`,
`containers`, `virtualization`, and `cluster`. Individual `--with-*` flags are
listed by `./install.sh --help`; a non-interactive run must use one of those
options. OpenSSH is part of the core package set and cannot be deselected. No
keys or checksum environment variables are required.
Without `--update-public-key`, the update facility stays disabled. NodeSource,
Docker, and K3s use their official HTTPS sources by default; optional SHA-256
environment variables add explicit pinning. K3s installs its compatible
`kubectl` by default. If `KUBECTL_VERSION` selects a separate version, the
installer fetches and validates its official checksum when `KUBECTL_SHA256` is
not supplied. When ZFS is selected and unavailable from the configured APT
sources, the installer adds a Debian-signed `contrib` source for the current
Debian release because Debian distributes `zfsutils-linux` in that component.
It checks for an installable APT candidate and installs `zfs-dkms` with the
running kernel’s headers so the ZFS kernel module can be built.

---

## Manual Installation

### Backend (`upcode-harbor-service`)

```bash
cd upcode-harbor-service
pip install --no-deps -r requirements.lock

# Initialize database
alembic upgrade head

# Generate encryption key
python generate_encryption_key.py

# Start the public API and mandatory cluster HTTPS listener
python main.py
```

### Frontend (`upcode-harbor`)

```bash
cd upcode-harbor
npm ci
npm run build
npm start      # Production mode on port 9200
# or
npm run dev    # Development mode with Turbopack
```

---

## Service Architecture (systemd)

The installer configures these systemd units:

| Service | Description |
|---|---|
| `upcode-harbor-api.service` | Loopback FastAPI API on port 9500 and cluster TLS transport on port 9501 |
| `upcode-harbor-web.service` | Loopback Next.js frontend on port 9200 |
| `upcode-harbor-worker.service` | Persistent transactional job worker |
| `upcode-harbor-health.timer` | Recurring liveness probe and recovery trigger |
| `upcode-harbor-update@.service` | Independent root unit for one signed release |

The browser-facing frontend and `/api` proxy must be served over HTTPS. Port
9200 and the backend's port 9500 are upstream listeners, not production browser
entry points. The default secure session cookie is intentionally not sent over
plain HTTP. Terminate TLS at Nginx or another trusted reverse proxy and forward
`/` to port 9200, `/api/` to port 9500, and WebSocket upgrades under `/ws/`.
Do not disable `UPCODE_HARBOR_COOKIE_SECURE` in production.

---

## Configuration Files

| File / Path | Content |
|---|---|
| `/etc/upcode-harbor/encryption.key` | Fernet encryption key (chmod 600) |
| `/etc/upcode-harbor/.session_secret` | Session-signing secret (chmod 600) |
| `/etc/upcode-harbor/sessions.json` | Hashed, revocable session records (chmod 600) |
| `/etc/upcode-harbor/api_tokens.json` | Hashed API-token records (chmod 600) |
| `/etc/upcode-harbor/notifications.json` | Email & webhook configuration |
| `/etc/upcode-harbor/alerts.json` | Alert thresholds |
| `/etc/upcode-harbor/metrics/` | Historical metrics (JSON) |
| `/etc/upcode-harbor/nodes/` | Cluster node configurations |
| `/etc/upcode-harbor/master` | Cluster master configuration |
| `/etc/upcode-harbor/child` | Cluster child configuration |
| `/etc/upcode-harbor/cluster-security/` | Node-local CA, certificate, and private keys (private files chmod 600) |
| `/var/log/upcode-harbor/api.log` | API log |
| `/var/log/upcode-harbor/worker.log` | Worker log |
| `/var/log/upcode-harbor/activity.log` | Structured activity log |
| `/var/lib/upcode-harbor/app-store/` | Mutable app store templates (`/opt/upcode-harbor/app-store` is a compatibility link) |
| `/var/lib/upcode-harbor/compose/` | Installed Docker Compose projects (`/opt/upcode-harbor/compose` is a compatibility link) |
| `/var/lib/upcode-harbor/app-data/` | Per-project managed App Store bind data |
| `/etc/upcode-harbor/settings.json` | Application settings (hostname, timezone, SSH and monitoring options) |
| `/etc/upcode-harbor/proxy_config.json` | Nginx proxy metadata |
| `upcode-harbor-service/network_settings.json` | Network settings |

---

## Update

Updates never use Git inside `/opt/upcode-harbor`. Build a versioned artifact on the
release system and sign it with the offline/private release key:

```bash
deploy/build-release-artifact 1.2.3 /secure/release-private.pem /tmp/upcode-harbor-1.2.3
```

Copy the three output files into
`/var/lib/upcode-harbor/updates/1.2.3/` as root, make them root-owned and not writable
by group/other, and write `1.2.3` to the root-owned mode-`0640`
`/var/lib/upcode-harbor/updates/latest` marker. The Settings update action then queues
the external `upcode-harbor-update@1.2.3.service` unit.

The updater verifies the SHA-256 and detached signature, backs up
`/etc/upcode-harbor`, builds the new immutable release, switches
`/opt/upcode-harbor/current` atomically, performs readiness checks, and rolls back on
failure. Its non-zero exit code and error are preserved in the persistent job.
See [`../deploy/README.md`](../deploy/README.md) for the exact artifact names.

---

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| `FRONTEND_ORIGINS` | Comma-separated list of allowed CORS origins | All server IPs auto-detected |
| `UPCODE_HARBOR_SESSION_TTL_SECONDS` | User-session lifetime in seconds | `3600` |
| `UPCODE_HARBOR_COOKIE_SECURE` | Require HTTPS for the session cookie | `true` |
| `UPCODE_HARBOR_COOKIE_SAMESITE` | Session-cookie SameSite policy | `strict` |
| `UPCODE_HARBOR_COOKIE_DOMAIN` | Optional explicit session-cookie domain | unset |

All directories under `/etc/upcode-harbor` are enforced as `0700` and all regular
files as `0600` at startup. Symlinks in the configuration tree fail the
security initialization rather than being followed.

---

## Paths Requiring Root Privileges

- `/etc/upcode-harbor/` – Owner-only configuration (`upcode-harbor`)
- `/var/log/upcode-harbor/` – Backend logs (`upcode-harbor`)
- `/etc/nginx/` – Nginx configuration
- `/etc/letsencrypt/` – SSL certificates
- `/etc/ssh/sshd_config` – Read SSH configuration
- `/etc/hosts` – Set hostname
- Read systemd journal (`journalctl`)
- `nft` – Firewall rules
- `docker` – Container management
- `virsh` / `qemu-img` – VM management

The web process has no privileged access. Docker, LXD, and libvirt/KVM groups
are added to the backend account only for selected profiles. All other host
mutations go through `/usr/local/libexec/upcode-harbor-privileged`; the sudoers policy
permits that helper and no other root command. Run the installed audit with:

```bash
sudo /usr/local/libexec/upcode-harbor-post-install-smoke
```
