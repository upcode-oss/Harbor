"""Static regression tests for the supported installation contract."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


def test_release_version_is_consistent_across_all_shipped_surfaces():
    version = (ROOT / "VERSION.md").read_text().strip()
    package = json.loads((ROOT / "upcode-harbor/package.json").read_text())
    package_lock = json.loads((ROOT / "upcode-harbor/package-lock.json").read_text())
    api = (ROOT / "upcode-harbor-service/main.py").read_text()
    cli = (ROOT / "upcode-harbor-cli/cli/main.py").read_text()
    sidebar = (ROOT / "upcode-harbor/components/sidebar.tsx").read_text()

    assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
    assert package["version"] == version
    assert package_lock["version"] == version
    assert package_lock["packages"][""]["version"] == version
    assert f'version="{version}"' in api
    assert f'VERSION = "{version}"' in cli
    assert f">v{version}<" in sidebar
    assert (ROOT / f"releases/{version}.md").is_file()
    assert f"## [{version}]" in (ROOT / "CHANGELOG.md").read_text()
    assert f"Release v{version}" in (ROOT / "RELEASE.md").read_text()


def test_release_uses_upcode_harbor_as_its_only_product_name():
    package = json.loads((ROOT / "upcode-harbor/package.json").read_text())
    package_lock = json.loads((ROOT / "upcode-harbor/package-lock.json").read_text())
    api = (ROOT / "upcode-harbor-service/main.py").read_text()
    cli = (ROOT / "upcode-harbor-cli/cli/main.py").read_text()
    installer = (ROOT / "install.sh").read_text()
    layout = (ROOT / "upcode-harbor/app/layout.tsx").read_text()

    assert package["name"] == "upcode-harbor"
    assert package_lock["name"] == "upcode-harbor"
    assert package_lock["packages"][""]["name"] == "upcode-harbor"
    assert 'title="Upcode Harbor API"' in api
    assert 'version=f"Upcode Harbor {VERSION}"' in cli
    assert "Open Upcode Harbor: https://%s/" in installer
    assert 'title: "Upcode Harbor"' in layout
    assert (ROOT / "upcode-harbor").is_dir()
    assert (ROOT / "upcode-harbor-service").is_dir()
    assert (ROOT / "upcode-harbor-cli/upcode-harbor").is_file()
    assert (ROOT / "deploy/systemd/upcode-harbor.target").is_file()
    assert (ROOT / "deploy/upcode-harbor-updater").is_file()

    shipped_paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    ).split(b"\0")
    forbidden_names = (
        b"Upserv" + b"X",
        b"UpServ" + b"X",
        b"up" + b"servx",
        b"UPS" + b"ERVX",
    )
    offenders = []
    for raw_path in shipped_paths:
        if not raw_path:
            continue
        path = ROOT / raw_path.decode()
        if not path.is_file():
            continue
        content = path.read_bytes()
        if any(name in content for name in forbidden_names):
            offenders.append(str(path.relative_to(ROOT)))

    assert not offenders, f"legacy product name remains in: {offenders}"


def test_installer_is_profile_based_and_does_not_patch_distribution_pam_or_pull_git():
    installer = (ROOT / "install.sh").read_text()
    assert "pam_lastlog" not in installer
    assert "git pull" not in installer
    assert "--profile containers" in installer
    assert "--with-postgresql" in installer
    assert "npm ci" in installer
    assert "requirements.lock" in installer
    assert "libpam-modules libpam-modules-bin libpam-runtime pamtester" in installer
    assert "NODESOURCE_KEY_SHA256" in installer
    assert "K3S_INSTALL_SHA256" in installer
    assert "DOCKER_GPG_SHA256" in installer


def test_linux_login_uses_a_dedicated_managed_pam_service():
    installer = (ROOT / "install.sh").read_text()
    auth = (ROOT / "upcode-harbor-service/api/auth.py").read_text()
    pam_client = (ROOT / "upcode-harbor-service/lib/pam_auth.py").read_text()
    privileged = (ROOT / "deploy/upcode-harbor-privileged").read_text()
    updater = (ROOT / "deploy/upcode-harbor-updater").read_text()
    pam_policy = (ROOT / "deploy/pam/upcode-harbor").read_text()

    assert (
        'install -o root -g root -m 0644 '
        '"$RELEASE_DIR/deploy/pam/upcode-harbor" /etc/pam.d/upcode-harbor'
    ) in installer
    assert "/etc/pam.d/upcode-harbor" in updater
    assert "from lib.pam_auth import PAM_SERVICE" in auth
    assert 'PAM_SERVICE = "upcode-harbor"' in pam_client
    assert "service=PAM_SERVICE" in auth
    assert 'run_privileged(\n                "pam-authenticate"' in pam_client
    assert '"authenticate",\n                "acct_mgmt",' in privileged
    assert "input=password_input" in privileged
    assert "@include common-auth" in pam_policy
    assert "@include common-account" in pam_policy


def test_installer_defaults_to_keyless_installation():
    installer = (ROOT / "install.sh").read_text()
    assert "UPDATES_ENABLED=0" in installer
    assert "UPDATE_PUBLIC_KEY=$2; UPDATES_ENABLED=1" in installer
    assert 'verify_optional_sha256 "${NODESOURCE_KEY_SHA256:-}"' in installer
    assert 'verify_optional_sha256 "${DOCKER_GPG_SHA256:-}"' in installer
    assert 'verify_optional_sha256 "${K3S_INSTALL_SHA256:-}"' in installer
    assert "if [[ -n ${KUBECTL_VERSION:-} ]]" in installer
    assert 'command -v kubectl' in installer


def test_installer_has_space_toggle_checklist_and_always_installs_ssh():
    installer = (ROOT / "install.sh").read_text()
    smoke = (ROOT / "deploy/upcode-harbor-post-install-smoke").read_text()

    assert "INSTALL_SELECTION_MADE=0" in installer
    assert "if [[ $INSTALL_SELECTION_MADE == 0 ]]; then\n  select_optional_components" in installer
    assert "apt-get install -y whiptail" in installer
    assert "--separate-output" in installer
    assert "--checklist" in installer
    assert "Arrow keys: Navigate | Space: Toggle | Tab: Select button" in installer
    assert "OpenSSH is always installed and cannot be deselected" in installer
    assert "docker 'Docker Container Runtime' OFF" in installer
    assert "k3s 'K3s Kubernetes' OFF" in installer
    assert "lxc 'LXC/LXD Systemcontainer' OFF" in installer
    assert "zfs 'ZFS Storage' OFF" in installer
    assert "--with-lxc|--with-lxd) WITH_LXD=1" in installer
    assert "Select components with --profile or --with-* options" in installer
    assert "openssh-client openssh-server" in installer
    assert "systemctl enable --now ssh.service" in installer
    assert "upcode-harbor-zfs.sources" in installer
    assert "Components: contrib" in installer
    assert "Docker service is active" in smoke
    assert "LXC client is installed" in smoke
    assert "K3s service is active" in smoke
    assert "ZFS CLI is installed" in smoke


def test_iso_listing_does_not_try_to_create_a_privileged_host_directory():
    handler = (ROOT / "upcode-harbor-service/handlers/isos.py").read_text()
    assert 'ISO_DIR = os.getenv("UPCODE_HARBOR_ISO_DIR", "/var/lib/libvirt/isos")' in handler
    assert "os.makedirs(iso_dir" not in handler
    assert "if not os.path.isdir(iso_dir):\n        return files" in handler


def test_installer_can_import_encryption_module_when_initializing_secrets():
    installer = (ROOT / "install.sh").read_text()
    assert 'PYTHONPATH="$RELEASE_DIR/upcode-harbor-service"' in installer
    assert "from lib.encryption import EncryptionManager" in installer
    assert "from lib.session_tokens import _get_secret" in installer
    assert "from lib.cluster_security import ensure_node_tls" in installer
    assert "EncryptionManager.ensure_key_exists(); _get_secret(); ensure_node_tls()" in installer


def test_installer_can_safely_resume_after_release_creation():
    installer = (ROOT / "install.sh").read_text()
    assert "--resume) RESUME_INSTALLATION=1" in installer
    assert "load_recorded_profile" in installer
    assert "stat -c '%U:%a'" in installer
    assert '[[ -L $APP_ROOT/current ]]' in installer
    assert 'RELEASE_DIR=$(readlink -f "$APP_ROOT/current")' in installer
    assert '[[ ${RELEASE_DIR%/*} == "$APP_ROOT/releases"' in installer
    assert "TOTAL_STEPS=7" in installer
    assert "run_step 'Configure mutable state and update trust'" in installer
    assert "run_step 'Configure the local HTTPS reverse proxy'" in installer
    assert "run_step 'Generate application, session, and cluster keys'" in installer
    assert "Installation resumed successfully" in installer


def test_installer_can_recoverably_reinstall_a_broken_installation():
    installer = (ROOT / "install.sh").read_text()
    assert "--reinstall) REINSTALL=1" in installer
    assert "--resume and --reinstall cannot be used together" in installer
    assert 'REINSTALL_BACKUP_DIR="/var/backups/upcode-harbor/$backup_id"' in installer
    assert '"$APP_ROOT"\n    /etc/upcode-harbor\n    /var/lib/upcode-harbor' in installer
    assert "/usr/local/libexec/upcode-harbor-bin" in installer
    assert "/etc/systemd/system/upcode-harbor.target" in installer
    assert 'mv -- "$source" "$REINSTALL_BACKUP_DIR/${labels[$index]}"' in installer
    assert installer.index(
        "run_step 'Validate locked source and noVNC submodule'"
    ) < installer.index("if [[ $REINSTALL == 1 ]]; then\n  backup_broken_installation")
    assert "Previous installation backup" in installer


def test_installer_does_not_create_application_login_users():
    installer = (ROOT / "install.sh").read_text()
    assert "upcode-harbor-admin" not in installer
    assert "--reset-admin" not in installer
    assert "INITIAL_ADMIN_PASSWORD" not in installer
    assert "Login with an existing Linux/PAM" in installer
    assert "TOTAL_STEPS=14" in installer


def test_frontend_api_worker_and_update_have_separate_units():
    units = ROOT / "deploy" / "systemd"
    api = (units / "upcode-harbor-api.service").read_text()
    web = (units / "upcode-harbor-web.service").read_text()
    worker = (units / "upcode-harbor-worker.service").read_text()
    updater = (units / "upcode-harbor-update@.service").read_text()
    assert "User=upcode-harbor\n" in api
    assert "User=upcode-harbor-web\n" in web
    assert "User=upcode-harbor\n" in worker
    assert "User=root\n" in updater
    assert "upcode-harbor-updater apply %i" in updater
    assert "upcode-harbor-health-check wait-api" in api
    assert "upcode-harbor-health-check wait-web" in web


def test_public_access_uses_nginx_https_instead_of_internal_ports():
    installer = (ROOT / "install.sh").read_text()
    web = (ROOT / "deploy/systemd/upcode-harbor-web.service").read_text()
    nginx = (ROOT / "deploy/nginx/upcode-harbor.conf").read_text()
    assert "--hostname 127.0.0.1" in web
    assert "listen 443 ssl default_server" in nginx
    assert "proxy_pass http://127.0.0.1:9200" in nginx
    assert "Open Upcode Harbor: https://%s/" in installer
    assert "remote access uses nginx on HTTPS port 443" in installer


def test_python_lock_files_pin_every_distribution_exactly():
    for relative in (
        "upcode-harbor-service/requirements.lock",
        "upcode-harbor-cli/requirements.lock",
        "requirements-quality.lock",
    ):
        lines = [
            line.strip() for line in (ROOT / relative).read_text().splitlines()
            if line.strip() and not line.startswith("#")
        ]
        assert lines
        assert all(re.fullmatch(r"[A-Za-z0-9_.-]+==[^=\s]+", line) for line in lines)
        names = [line.split("==", 1)[0].lower() for line in lines]
        assert len(names) == len(set(names))


def test_novnc_gitlink_has_an_explicit_official_mapping():
    mapping = (ROOT / ".gitmodules").read_text()
    assert "path = upcode-harbor/public/novnc" in mapping
    assert "url = https://github.com/novnc/noVNC.git" in mapping
    installer = (ROOT / "install.sh").read_text()
    assert "submodule update --init --checkout" in installer
    assert "--remote" not in installer


def _installer_function(name):
    installer = (ROOT / "install.sh").read_text()
    match = re.search(rf"^{name}\(\) \{{\n.*?^\}}", installer, re.M | re.S)
    assert match, name
    return match.group(0)


def test_skip_nginx_does_not_run_proxy_or_certificate_commands():
    script = "set -eu\nSKIP_NGINX=1\nRELEASE_DIR=/test-release\n"
    for command in ("install", "openssl", "chown", "chmod", "rm", "ln", "nginx", "systemctl"):
        script += f'{command}() {{ echo "Unexpected command: {command}" >&2; exit 99; }}\n'
    script += _installer_function("step_configure_https") + "\n"
    script += _installer_function("print_access_information") + "\n"
    script += "step_configure_https\nprint_access_information\n"
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
    assert "Nginx setup skipped" in result.stdout
    assert "http://127.0.0.1:9200" in result.stdout
    assert "Open Upcode Harbor: https://" not in result.stdout


def test_nginx_packages_are_optional_but_ssh_remains_enabled():
    installer = (ROOT / "install.sh").read_text()
    packages = re.search(r"^CORE_PACKAGES=\(.*?^\)", installer, re.M | re.S).group(0)
    for skip in (0, 1):
        script = f"set -eu\nSKIP_NGINX={skip}\n" + packages + "\n"
        for component in ("ZFS", "LXD", "LIBVIRT", "POSTGRESQL", "FTP", "OPENVPN"):
            script += f"WITH_{component}=0\n"
        script += 'apt-get() { printf "%s\\n" "$@"; }\n'
        script += 'systemctl() { printf "%s\\n" "$@"; }\n'
        script += _installer_function("step_install_core_packages") + "\nstep_install_core_packages\n"
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
        arguments = result.stdout.splitlines()
        for package in ("nginx", "certbot", "python3-certbot", "python3-certbot-nginx"):
            assert (package in arguments) == (skip == 0)
        assert "openssh-server" in arguments
        assert "ssh.service" in arguments


def test_resume_restores_nginx_choice_and_respects_explicit_override(tmp_path):
    profile = tmp_path / "install-profile"
    function = _installer_function("load_recorded_profile").replace(
        "/var/lib/upcode-harbor/install-profile", str(profile)
    )
    for recorded, explicit, expected in (("1", 0, "1"), ("1", 1, "0"), ("0", 0, "0")):
        profile.write_text(f"SKIP_NGINX={recorded}\nWITH_DOCKER=1\n")
        script = f"set -eu\nSKIP_NGINX=0\nNGINX_SELECTION_MADE={explicit}\n"
        script += 'stat() { echo root:640; }\n' + function
        script += '\nload_recorded_profile\nprintf "%s" "$SKIP_NGINX"\n'
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
        assert result.stdout == expected



def test_installer_downloads_pinned_novnc_and_preserves_local_changes(tmp_path):
    env = dict(os.environ, GIT_ALLOW_PROTOCOL="file", GIT_CONFIG_COUNT="1",
               GIT_CONFIG_KEY_0=f"url.{tmp_path}/novnc-origin.insteadOf",
               GIT_CONFIG_VALUE_0="https://github.com/novnc/noVNC.git")

    def git(directory, *args):
        return subprocess.check_output(
            ["git", "-C", str(directory), *args], env=env, text=True,
            stderr=subprocess.PIPE,
        ).strip()

    origin = tmp_path / "novnc-origin"
    origin.mkdir()
    git(origin, "init")
    git(origin, "config", "user.name", "Installer test")
    git(origin, "config", "user.email", "installer@example.invalid")
    (origin / "vnc.html").write_text("pinned version")
    git(origin, "add", ".")
    git(origin, "commit", "-m", "Pinned noVNC")
    pinned = git(origin, "rev-parse", "HEAD")

    source = tmp_path / "source"
    source.mkdir()
    git(source, "init")
    git(source, "config", "user.name", "Installer test")
    git(source, "config", "user.email", "installer@example.invalid")
    git(source, "submodule", "add", "https://github.com/novnc/noVNC.git",
        "upcode-harbor/public/novnc")
    (source / "upcode-harbor/package-lock.json").write_text("{}")
    (source / "upcode-harbor-service").mkdir()
    (source / "upcode-harbor-service/requirements.lock").write_text("")
    git(source, "add", ".")
    git(source, "commit", "-m", "Pin submodule")
    (origin / "vnc.html").write_text("new upstream version")
    git(origin, "commit", "-am", "New upstream")

    checkout = tmp_path / "checkout"
    git(tmp_path, "clone", str(source), str(checkout))
    novnc = checkout / "upcode-harbor/public/novnc"
    assert not (novnc / "vnc.html").exists()
    script = 'set -eu\nSCRIPT_DIR=$1\n' + _installer_function("step_validate_source")
    script += "\nstep_validate_source\n"

    def validate():
        return subprocess.run(["bash", "-c", script, "installer-test", str(checkout)],
                              env=env, capture_output=True, text=True)

    result = validate()
    assert result.returncode == 0, result.stderr
    assert git(novnc, "rev-parse", "HEAD") == pinned
    assert (novnc / "vnc.html").read_text() == "pinned version"
    assert validate().returncode == 0

    git(novnc, "checkout", "origin/HEAD")
    assert git(novnc, "rev-parse", "HEAD") != pinned
    assert validate().returncode == 0
    assert git(novnc, "rev-parse", "HEAD") == pinned

    (novnc / "vnc.html").write_text("local changes")
    assert validate().returncode != 0
    assert (novnc / "vnc.html").read_text() == "local changes"
