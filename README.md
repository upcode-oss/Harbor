# Upcode Harbor - Server Management Platform

<p align="center">
  <img src="upcode-harbor/public/logo.png" alt="Upcode Harbor Logo" width="400">
</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python](https://img.shields.io/badge/Python-3.11+-blue.svg)](https://www.python.org/downloads/)
[![Next.js](https://img.shields.io/badge/Next.js-16.x-black.svg)](https://nextjs.org/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.128.x-009688.svg)](https://fastapi.tiangolo.com/)

A comprehensive web-based server management platform with Docker container management, integrated app store, backup system, and system monitoring. Upcode Harbor simplifies managing your server infrastructure with a modern, user-friendly interface.

## 🚀 Features

- 📦 **Container and VM Management** - Container lifecycle, logs, image management
- 🏪 **Integrated App Store** - 62 validated, versioned templates (WordPress, TYPO3, Nextcloud, Jellyfin, MySQL, PostgreSQL, MongoDB, Redis, Grafana, Prometheus, Pi-hole, and more)
- 💾 **Automated Backup System** - Scheduled backups with Cron, local and SSH remote storage
- 👥 **User & Group Management** - System users, SSH keys, permissions
- 🌐 **Network Management** - Interface configuration, IP management
- 🛠️ **System Services** - SystemD service management and monitoring
- 📊 **System Monitoring** - Real-time metrics (CPU, RAM, Disk, Network)
- 🗄️ **Storage Management** - Disk management, ZFS pools, mount points
- 🎨 **Modern UI** - Dark/Light theme, responsive design with Next.js & Tailwind CSS

## 📦 App Store Templates

Upcode Harbor includes 62 pre-configured app templates for quick deployments:

**CMS & Web:**
- WordPress, TYPO3, Nextcloud, Jitsi

**Media:**
- Jellyfin, Emby, Plex

**Development:**
- Gitea, n8n

**Databases:**
- MySQL, PostgreSQL, MongoDB, InfluxDB, Redis

**Monitoring & Tools:**
- Grafana, Prometheus, phpMyAdmin, Adminer

**Network:**
- Nginx Proxy Manager, Pi-hole, TeamSpeak, Vaultwarden

All templates are located in the `app-store-templates/` folder and can be easily extended.

## Local quality gates

Run the same mandatory checks used by CI from a clean checkout:

```bash
make test
```

The command uses Python 3.11 to match CI (set `UPCODE_HARBOR_TEST_PYTHON` to an
explicit compatible interpreter), and requires Node.js 20+, npm, and Docker
Compose. It
creates an isolated temporary Python virtual environment from the locked
dependency files, so it does not use or modify the repository's `.venv`. It
validates every App Store manifest and rendered Compose file, checks generated
OpenAPI client types, runs backend and CLI tests and Python/shell syntax checks,
then runs the frontend ESLint and production build gates.

## 📋 Prerequisites

- **Operating System**: Linux Debian
- **Python**: 3.11 or higher
- **Node.js**: 20 or higher
- **Docker/K3s/LXC/ZFS**: Selected in an interactive checklist; automation profiles remain available
- **OpenSSH server**: Always installed and enabled
- **Root Access**: Required only to run the installer and signed updater

## ⚡ Installation

### Quick Installation

```bash
# Clone repository
git clone https://github.com/upcode-at/upcode-harbor.git
cd upcode-harbor

# Interactive selection (no keys required)
sudo ./install.sh

# Explicit minimal install
sudo ./install.sh --profile core

# Non-interactive full install with signed updates
sudo ./install.sh --profile full \
  --update-public-key /secure/release-public.pem
```

The installer creates dedicated `upcode-harbor` and `upcode-harbor-web` accounts, immutable
versioned releases, separate API/frontend/worker systemd units, an HTTPS nginx
entry point, and a post-install privilege/health smoke test. With no component
options it opens a terminal checklist for Docker, K3s/kubectl, LXC/LXD, and
ZFS. Navigate with the arrow keys, toggle entries with Space, and confirm with
Tab/Enter. The SSH server is always installed and enabled. `--profile core`
provides a non-interactive minimal deployment, while `--profile full` selects
all supported components. Without
`--update-public-key`, the update facility stays disabled. Optional SHA-256
environment variables can additionally pin remote installation material. See
[`docs/installation.md`](docs/installation.md) for optional checksum pinning and
the signed update workflow.

After installation, use the printed `https://SERVER-IP/` URL. Ports `9200` and
`9500` are intentionally loopback-only internal services. Sign in with an
existing Linux/PAM user through the dedicated `upcode-harbor` PAM service; the
installer does not create application login users.

### Complete technical rename in 0.7.0

Version 0.7.0 uses `upcode-harbor` consistently for source directories,
service accounts, systemd units, PAM, filesystem paths, helper binaries, the
CLI command, environment variables, release manifests, and signed artifacts.
No compatibility aliases for the previous technical namespace are installed.
Consequently, 0.7.0 requires a clean installation instead of an in-place
update from 0.6.x or older.


## 💝 Support

Want to support the project? Here are some ways to help:

### ⭐ GitHub Star
Give the project a star on [GitHub](https://github.com/upcode-at/upcode-harbor) - it helps others discover it!

### 🐛 Issues & Feedback
- Report bugs via [GitHub Issues](https://github.com/upcode-at/upcode-harbor/issues)
- Share feature requests and suggestions
- Help improve the documentation

### 🤝 Contribute
1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Commit your changes: `git commit -am 'Add feature'`
4. Push to the branch: `git push origin feature-name`
5. Create a Pull Request

### 💰 Sponsoring
Support development financially:
- [GitHub Sponsors](https://github.com/sponsors/upcode-at)

### 📢 Spread the Word
- Share the project on social media
- Write a blog post about it
- Recommend it to friends and colleagues

Every contribution helps make Upcode Harbor better! 🙏

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📞 Contact & Community

- **GitHub**: [upcode-at/upcode-harbor](https://github.com/upcode-at/upcode-harbor)
- **Issues**: [Bug Reports & Feature Requests](https://github.com/upcode-at/upcode-harbor/issues)
- **Discussions**: [GitHub Discussions](https://github.com/upcode-at/upcode-harbor/discussions)

---

**Upcode Harbor** - Server management made easy 🚀
