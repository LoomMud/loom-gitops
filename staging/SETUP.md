<!--
SPDX-FileCopyrightText: 2026 Oberfield
SPDX-License-Identifier: AGPL-3.0-only
-->

# Loom host (`loom`): board setup guide (Ubuntu 26.04 LTS)

**Audience:** Oberfield board admins provisioning the Docker Compose host requested in OBI-56.
**Target:** Ubuntu Server **26.04 LTS "Resolute Raccoon"**, x86_64 (amd64). Machine name **`loom`**.
**Names:** admins reach the machine directly at **`system.loommud.com`** (DNS only). Players and the web reach it at **`loommud.com`** and **`www.loommud.com`**, which are **proxied through Cloudflare**.
**Backups:** **Azure Blob Storage** (replaces the S3 bucket in earlier revisions).
**Design reference:** OBI-8 plan r4 §3.4 (decisions D-P1.7 to D-P1.14). Stack implementation: R6 / OBI-42 (Legolas). The stack files still live under `staging/` in this repo. That is the repo layout R6 chose, not a host, user or DNS name.
**Time:** about 60–90 min for sections 1–8, plus about 15 min for section 9 (after R6 ships `staging/bootstrap.sh`).

> **Golden rule.** The only things that ever go into a Paperclip comment are the **hostnames**, the **public IP** and the **age public key** (`age1…`). Every other value in this guide (Azure SAS token, storage account key, GitHub tokens, Postgres password, Cloudflare credentials, age *private* key) goes into `/etc/loom/secrets.env` on the host and/or the board password manager, and nowhere else. See §10.

Items marked **TBD-by-R6** depend on files R6 (OBI-42) has not shipped yet. Do not guess them. Skip that step until the repo has the file, or ask on OBI-42.

### What changed in this revision (OBI-106)
- **Agents now have SSH access.** This is a board decision (OBI-58) that reverses the earlier "agents have no SSH" rule (OBI-8 §3.4 / OBI-56). A dedicated `loom-agent` account with passwordless sudo lets Paperclip agents run §1–§5 and §9 themselves. The access model, and how to revoke it with one line, is in the new **§3.6**.
- **Steady state is unchanged.** Deploys still go only through reviewed `loom-gitops` PRs, the reconciler and cosign verification. Agent SSH is for provisioning and break-glass work, not for day-to-day deploys.
- **SSH:** the intended allow-list is board admin IPs **plus the Paperclip egress IP** (§4.2). On `system.loommud.com`, the board kept 22 open instead, because that IP is dynamic, and added fail2ban.
- **Admins aren't in the `docker` group** (§3.1). `greg` was removed on OBI-106 and uses `sudo docker`.
- **`secrets.env` variable names** are now fixed in `staging/secrets.env.example` (CTO decision; R6 must use them). §9.2 names the exact line where the board pastes the GitHub token.
- **Firewall markers:** the ufw `after.rules` markers are now `LOOM …`; the old `LOOM-STAGING …` markers are gone.

### Previous revision (OBI-62)
- Machine name `loom`. Service user `loom` (was `loom-staging`). Secrets directory `/etc/loom` (was `/etc/loom-staging`). No "staging" in any user or DNS name.
- DNS: `system.loommud.com` (DNS only, direct: SSH and telnet) plus `loommud.com` / `www.loommud.com` (Cloudflare-proxied: HTTPS and WSS). New §5 covers Cloudflare settings; §4.5 limits 80/443 to Cloudflare; §9 checks updated.
- Backups: Azure Blob Storage with a container-scoped SAS token and an Azure lifecycle policy, instead of AWS/S3 (§6).

---

## Map: OBI-56 items → sections

| OBI-56 item | Section(s) |
|---|---|
| 1. Host: VM, Docker ≥ 24 + Compose v2, systemd, git, Docker at boot, outbound HTTPS | §1 Base OS, §2 Packages, §3 Users & permissions, §4.4 Outbound |
| 2. DNS hostname with A/AAAA | §5 DNS & Cloudflare |
| 3. Firewall: 4000/80/443 in, SSH for admins only, rest closed | §3.2 SSH hardening, §4 Firewall |
| 4. Backup bucket, scoped key, ~90-day lifecycle | §6 Backup storage (Azure Blob) |
| 5. age keypair, private key offline, post public key | §7 age keypair |
| 6. GitHub fine-grained tokens (commit statuses; alerting issues) | §8.1, §8.1b GitHub tokens |
| 7. GHCR public (fallback `read:packages` token) | §8.2 GHCR |
| 8. One-time bootstrap | §9 Bootstrap & verification |

Suggested order: §0 → §1 → §2 → §3 → §4 → §5, with §6, §7 and §8 done in parallel from an admin workstation. §9 comes later, when OBI-42 reaches its evidence step.

---

## 0. Before you start

### 0.1 Values sheet

Fill this in before you start (in your password manager or on paper, **not** in Paperclip). The shell snippets below use these names.

| Name | Value / example | Secret? |
|---|---|---|
| Machine name | `loom` | no |
| `SYSTEM_FQDN` | `system.loommud.com` (DNS only, points straight at the host) | no (post on OBI-56) |
| `PUBLIC_FQDNS` | `loommud.com`, `www.loommud.com` (Cloudflare-proxied) | no |
| `PUBLIC_IPV4` | `203.0.113.10` | no (post on OBI-56) |
| `PUBLIC_IPV6` | `2001:db8::10`, or *none* | no |
| `ADMIN_USER` | `alice` (one per board admin) | no |
| `ADMIN_SRC_IPS` | `198.51.100.7/32` (board admins' public IPs) | keep private, not secret |
| `AZ_RG` | `loom-backups-rg` (Azure resource group) | no |
| `AZ_REGION` | `westeurope` | no |
| `AZ_STORAGE_ACCOUNT` | `loommudbackups` (globally unique, 3–24 lowercase letters/digits) | no |
| `AZ_CONTAINER` | `loom-backups` | no |
| Storage account key | … (used on the admin workstation only, **never** on the host) | **SECRET** |
| Container SAS token | `sp=…&sig=…` | **SECRET** |
| GitHub fine-grained token (statuses) | `github_pat_…` | **SECRET** |
| GHCR `read:packages` token (fallback only) | `ghp_…` | **SECRET** |
| Postgres password | generated in §9 | **SECRET** |
| Cloudflare account login | … | **SECRET** (password manager) |
| age private key | `AGE-SECRET-KEY-1…` | **SECRET, offline only, never on the host** |
| age public key | `age1…` | no (post on OBI-56) |

### 0.2 What you need
- A cloud/VPS account (any provider with Ubuntu 26.04 images) or a hypervisor.
- The `loommud.com` zone on **Cloudflare**, with rights to edit DNS and SSL/TLS settings.
- An **Azure subscription** where you can create a resource group and storage account, and the Azure CLI (`az`) on an admin workstation (`az login`). Ideally the VM is **not** in the same Azure subscription, so losing the host account doesn't also lose the backups.
- An SSH key pair on each admin's workstation (`ssh-keygen -t ed25519` if you don't have one).
- Owner/admin rights on the `LoomMud` GitHub org (for the token policy and GHCR visibility).
- `age` on an offline or trusted workstation (§7).

---

## 1. Base OS

### 1.1 Create the VM
- **Name:** `loom`.
- **Image:** Ubuntu Server 26.04 LTS, amd64 (the minimal or cloud image is fine).
- **Size:** at least **2 vCPU / 4 GB RAM / 40 GB SSD**. Use one disk; no extra volumes are needed (Docker named volumes live under `/var/lib/docker`).
- **Network:** a static public IPv4 (reserved/elastic IP). IPv6 is optional; see §5 before you publish an AAAA record.
- **Provider firewall / security group** (if the provider has one): allow inbound TCP 22 from `ADMIN_SRC_IPS` only, TCP 4000 from anywhere, and TCP 80/443 from anywhere (or from Cloudflare's ranges only, see §4.5). Deny everything else. This is a second layer on top of ufw (§4).
- **SSH key:** inject the first admin's public key at creation (cloud-init). Most images create a default `ubuntu` user with it.

SSH in as the default user (for example `ssh ubuntu@PUBLIC_IPV4`; once §5 is done, `ssh ubuntu@system.loommud.com`). Everything below runs on the host unless it says otherwise.

### 1.2 Update the system
```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y
# Reboot only if one is required (for example, after a new kernel)
[ -f /var/run/reboot-required ] && sudo reboot
```

### 1.3 Hostname
```bash
sudo hostnamectl set-hostname loom
# Stop cloud-init from resetting it on reboot
echo 'preserve_hostname: true' | sudo tee /etc/cloud/cloud.cfg.d/99-loom-hostname.cfg
# Make sure the name resolves locally
grep -qw 'loom' /etc/hosts || echo '127.0.1.1 system.loommud.com loom' | sudo tee -a /etc/hosts
hostnamectl                # expect: Static hostname: loom
```
The OS hostname is `loom`. Its public, direct name is `system.loommud.com` (§5).

### 1.4 Timezone and NTP
Use UTC on servers, so logs, backup timestamps and GitHub statuses line up.
```bash
sudo timedatectl set-timezone Etc/UTC
# Ubuntu 25.10+ ships chrony (with NTS) as the time daemon. Install it if it's missing:
command -v chronyc >/dev/null || sudo apt install -y chrony
sudo systemctl enable --now chrony
timedatectl status          # expect: "System clock synchronized: yes", "NTP service: active"
chronyc tracking            # expect: "Leap status : Normal"
```

### 1.5 Automatic security updates (unattended-upgrades)
```bash
sudo apt install -y unattended-upgrades apt-listchanges
# Turn on the daily update + upgrade jobs
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
# Loom-specific policy: also patch Docker from its repo (added in §2), and reboot at night if needed.
# Containers come back on their own (Docker enabled at boot + restart: unless-stopped).
sudo tee /etc/apt/apt.conf.d/52loom-unattended >/dev/null <<'EOF'
Unattended-Upgrade::Origins-Pattern {
        "origin=Docker,label=Docker CE,codename=${distro_codename}";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
sudo systemctl enable --now unattended-upgrades
```
Run the verification after §2, once the Docker repo exists:
```bash
sudo unattended-upgrade --dry-run --debug 2>&1 | grep -iE 'allowed origins|origin=Docker'
```
The 04:30 UTC reboot window is fine for an internal alpha: players see at most one reconnect. The nightly backup time (R6) should not overlap it (**TBD-by-R6:** backup schedule).

---

## 2. Packages

### 2.1 Docker Engine + Compose v2 (official Docker apt repo)
Docker publishes a `resolute` (26.04) suite at `download.docker.com` (checked 2026-09: `docker-ce 29.x`, `docker-compose-plugin 5.x`). Follow the official procedure:
```bash
# Remove any distro or snap Docker packages that would conflict (it's fine if none are installed)
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt remove -y "$pkg" 2>/dev/null || true
done
sudo snap remove docker 2>/dev/null || true

# Prerequisites
sudo apt update
sudo apt install -y ca-certificates curl gnupg

# Docker's apt signing key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
# Check the fingerprint. It MUST be: 9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88
gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.asc

# The repo (deb822 format)
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker containerd
```

**Fallback if the Docker repo is unavailable** (for example, `apt update` reports `404 … resolute Release`): use Ubuntu's own packages. They meet the ≥ 24 / Compose v2 bar (26.04 archive: `docker.io` 29.1.x, `docker-compose-v2` 2.40.x):
```bash
sudo rm -f /etc/apt/sources.list.d/docker.sources
sudo apt update
sudo apt install -y docker.io docker-compose-v2 docker-buildx
sudo systemctl enable --now docker containerd
```
If you use the fallback, drop the `origin=Docker` line from `/etc/apt/apt.conf.d/52loom-unattended`. Ubuntu's own security updates already cover these packages. Don't mix the two sources.

### 2.2 Docker daemon settings
Rotate logs (so they don't fill the disk) and keep containers running while `dockerd` itself is restarted or upgraded:
```bash
sudo install -d -m 0755 /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
EOF
sudo systemctl restart docker
```

### 2.3 Everything else
```bash
sudo apt install -y \
  git age ufw jq openssl \
  dnsutils netcat-openbsd telnet \
  cosign
```
| Package | Why |
|---|---|
| `git` | clone and fast-forward `loom-gitops` (reconciler, D-P1.8) |
| `age` | backup encryption tooling; lets the board run the restore drill with the offline key (D-P1.12). The host only ever holds the **public** key. |
| `ufw` | host firewall (§4) |
| `jq`, `curl` | reconciler posts the GitHub commit status; verification commands; Cloudflare IP list (§4.5) |
| `openssl` | generates the Postgres password; TLS checks |
| `dnsutils`, `netcat-openbsd`, `telnet` | DNS, port and telnet verification (§5, §9) |
| `fail2ban` | bans SSH brute-force sources, since 22 stays open (§4.2, OBI-106) |
| `cosign` | the reconciler verifies image signatures before deploying (D-P1.8). Ubuntu 26.04 universe ships cosign 2.x. **TBD-by-R6:** R6 may run cosign from a pinned container instead. Installing the package is harmless either way. |

The Azure CLI is **not** needed on the host. Backups upload from inside the `backup` container with `rclone` (Azure Blob backend) and a SAS token (§6).

**TBD-by-R6:** any further host prerequisites that `staging/bootstrap.sh` checks for. The design keeps `pg_dump`, `rclone` and `age` for backups **inside** the `backup` container, so the host needs nothing more for them. If `bootstrap.sh` reports a missing command, install it with `apt` and note it on OBI-42.

### 2.4 Check
```bash
docker --version                                   # >= 24 (expect 29.x)
docker compose version                             # v2+ (Docker repo: 5.x; Ubuntu fallback: 2.40.x)
systemctl is-enabled docker && systemctl is-active docker   # enabled / active
sudo docker run --rm hello-world                   # pulls from Docker Hub and prints "Hello from Docker!"
git --version; age --version; cosign version | head -3; ufw --version
```

---

## 3. Users & permissions

### 3.1 Admin users (SSH keys only)
Create **one named account per board admin**. Don't share an account. Repeat this block for each admin:
```bash
ADMIN_USER=alice                                   # <- change
ADMIN_PUBKEY='ssh-ed25519 AAAA...replace... alice@laptop'   # <- paste the PUBLIC key (the .pub file)

sudo adduser --disabled-password --comment "" "$ADMIN_USER"
sudo usermod -aG sudo "$ADMIN_USER"
sudo install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
echo "$ADMIN_PUBKEY" | sudo tee "/home/$ADMIN_USER/.ssh/authorized_keys" >/dev/null
sudo chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
sudo chmod 0600 "/home/$ADMIN_USER/.ssh/authorized_keys"
# A local password is needed for sudo only. SSH password login is disabled in 3.2.
sudo passwd "$ADMIN_USER"
```
**Before you continue:** open a **second** terminal and check that `ssh ADMIN_USER@PUBLIC_IPV4` works and `sudo -v` accepts the password. Keep your first session open until §3.2 and §4 are done and checked.

**Don't add admins to the `docker` group.** Use `sudo docker …`. See the caveat in §3.3.

### 3.2 SSH hardening (no passwords, no root)
Cloud images ship `/etc/ssh/sshd_config.d/50-cloud-init.conf`, which can re-enable password login. `sshd` uses the **first** value it reads, so name our drop-in `00-…` so that it wins:
```bash
sudo tee /etc/ssh/sshd_config.d/00-loom-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
# Only sudo-group accounts (the board admins + loom-agent, §3.6) may log in over SSH
AllowGroups sudo
EOF
sudo sshd -t && sudo systemctl restart ssh
# Check the effective settings
sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowgroups) '
# expect: permitrootlogin no / passwordauthentication no / kbdinteractiveauthentication no / allowgroups sudo
sudo passwd -l root        # lock the root password (it's normally locked already)
```
Check from your workstation, in a **new** session (use `PUBLIC_IPV4` until §5 is done):
```bash
ssh ADMIN_USER@system.loommud.com                                                    # works (key)
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password ADMIN_USER@system.loommud.com   # must fail: "Permission denied (publickey)"
ssh root@system.loommud.com                                                          # must fail
```
SSH always goes to `system.loommud.com`. `loommud.com` and `www` resolve to Cloudflare, which doesn't carry SSH.

Once your named admin works, disable the image's default user: `sudo usermod -L -s /usr/sbin/nologin ubuntu && sudo gpasswd -d ubuntu sudo`. To remove it completely, use `sudo deluser --remove-home ubuntu`.

(SSH source-IP restriction is done in the firewall, §4.2.)

### 3.3 Service user `loom`
One dedicated **system** account, with no login shell and no password. It owns the `loom-gitops` clone and runs the reconciler.
```bash
sudo useradd --system --user-group \
  --home-dir /var/lib/loom --create-home \
  --shell /usr/sbin/nologin \
  --comment "Loom reconciler" loom
sudo usermod -aG docker loom
id loom                    # expect: groups include loom and docker
```

> **Caveat: `docker` group = root.** Any member of the `docker` group can start a privileged container that mounts `/` and so gets full root on the host. `loom` needs this, because the reconciler runs `docker compose`. The account is safe only because:
> - it has no password and no login shell, and SSH is limited to the `sudo` group (§3.2);
> - in the steady state, agents change what runs on the host only through reviewed PRs to `loom-gitops`, and every image digest is cosign-verified before it runs (D-P1.8). The `loom-agent` account (§3.6) is root-equivalent by design. It exists for provisioning and break-glass work, is sudo-logged, and can be revoked in one line;
> - admins do **not** join `docker`. They use `sudo docker`, so root-level actions stay explicit and logged by sudo.
>
> Rootless Docker was considered and rejected for Phase 1: it complicates binding ports 80/443, plus systemd user sessions and reconciler ergonomics. This will be revisited with the Phase 2+ Flux move.

### 3.4 Secrets directory and file
```bash
sudo install -d -o root -g loom -m 0750 /etc/loom
# Empty placeholder with the right owner/mode. It's filled in during §9 from secrets.env.example.
sudo install -o root -g loom -m 0640 /dev/null /etc/loom/secrets.env
sudo stat -c '%n %U:%G %a' /etc/loom /etc/loom/secrets.env
# expect: /etc/loom root:loom 750
#         /etc/loom/secrets.env root:loom 640
```
Why `root:loom 0640`: root owns the file, so the service account can **read** it (Compose reads `env_file` on the client side) but can't change it. Nobody else can read it.

**Note for R6 (CTO decision, supersedes "root, 0600" in D-P1.13):** the reconciler systemd unit runs as `User=loom`, so the file is `/etc/loom/secrets.env` `root:loom 0640` and the directory is `/etc/loom` `root:loom 0750`. If `bootstrap.sh` enforces paths or modes, it must enforce these.

### 3.5 `loom-gitops` clone location
`LoomMud/loom-gitops` is a **public** repo, so the clone needs no credentials.
```bash
sudo install -d -o loom -g loom -m 0755 /opt/loom-gitops
sudo -u loom git clone https://github.com/LoomMud/loom-gitops.git /opt/loom-gitops
# Let root/admins run read-only git commands in the service-owned clone without "dubious ownership" errors
sudo git config --system --add safe.directory /opt/loom-gitops
sudo -u loom git -C /opt/loom-gitops log --oneline -1
```
- **Clone path:** `/opt/loom-gitops`, owned by `loom`. Only the reconciler writes to it (fast-forwarding `main`).
- **Never edit files in this clone by hand.** Changes go through PRs. The reconciler fast-forwards, and local edits would block it.
- **TBD-by-R6:** if `bootstrap.sh` expects a different clone path, follow the runbook and tell the CTO so this guide gets updated.

### 3.6 Agent access: `loom-agent` (OBI-58 / OBI-106)
The board lets Paperclip agents configure the host directly over SSH. The access is deliberately narrow and easy to revoke.

| What | Value |
|---|---|
| Account | `loom-agent` (uid ≥ 1000, `--disabled-password`, member of `sudo` so that `AllowGroups sudo` admits it) |
| Auth | one ed25519 public key in `/home/loom-agent/.ssh/authorized_keys`, comment `paperclip-agents@system.loommud.com`, fingerprint `SHA256:qtzsOjovNZhtip1wHAdzGFDlPsNjlHdL7uPUBKklk3Q` |
| Private key | only in Paperclip, as secret `infra/system.loommud.com/ssh-private-key`. It's bound to **Aragorn (CTO)** as `access.system_loommud_ssh_key`, fetched on demand through the API and never injected into the environment. Each run writes it to a `0600` file in its scratch directory and deletes it afterwards. It's never printed, committed or posted. |
| sudo | `/etc/sudoers.d/loom-agent`: `loom-agent ALL=(ALL) NOPASSWD:ALL`, mode `0440`. Agents can't answer password prompts. |
| Network | port 22 is allowed from the board admin IPs **and the Paperclip egress IP** (§4.2) |
| Host key pin | `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGV9ZR6qug6DJuozl4ZkxrOjXSBZApoDMLAoYX6adtUA` (`SHA256:fAPB5XV1cCFMvPMGY4T3VJjoPN+3DqAi278je//De3s`). Agents connect with `StrictHostKeyChecking=yes` against this pin. |
| Who has SSH | the board admins (named accounts, §3.1) and Paperclip agents through `loom-agent`. Nobody else. |

Set it up once, as a board admin:
```bash
sudo adduser --disabled-password --comment "Paperclip agents" loom-agent
sudo usermod -aG sudo loom-agent                    # required: sshd has AllowGroups sudo (§3.2)
sudo install -d -m 0700 -o loom-agent -g loom-agent /home/loom-agent/.ssh
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHOehHwgKrVYB+mA+MP167DDO2gxHDwv9V2aYHBVLOLU paperclip-agents@system.loommud.com' \
  | sudo tee /home/loom-agent/.ssh/authorized_keys >/dev/null
sudo chown loom-agent:loom-agent /home/loom-agent/.ssh/authorized_keys && sudo chmod 0600 /home/loom-agent/.ssh/authorized_keys
echo 'loom-agent ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/loom-agent >/dev/null
sudo chmod 0440 /etc/sudoers.d/loom-agent && sudo visudo -c
```
> **Pitfall (hit on OBI-106):** without `usermod -aG sudo`, sshd rejects the key with a bare `Permission denied (publickey)`. The key file looks fine, but `AllowGroups sudo` filters the user out before any key is checked.

**Revoke agent access** (any board admin, takes effect immediately; no restart needed):
```bash
sudo sed -i '/paperclip-agents@system.loommud.com/d' /home/loom-agent/.ssh/authorized_keys   # the one-line revoke
# Optional, for a full removal:
sudo gpasswd -d loom-agent sudo; sudo rm -f /etc/sudoers.d/loom-agent; sudo deluser --remove-home loom-agent
```
After revoking, also ask Gandalf to archive the Paperclip secret. To rotate the key, generate a new pair, replace the line, and update the Paperclip secret.

**Audit:** every agent command goes through `sudo`, so `sudo journalctl _COMM=sudo --since today` and `journalctl -u ssh | grep loom-agent` show what ran and when. Agents also post a summary of every change on the Paperclip issue.

**Steady state is still GitOps + cosign.** Agents use SSH for host provisioning, one-off bootstrap (§9) and break-glass debugging. What runs in the stack still changes **only** through reviewed `loom-gitops` PRs, the reconciler and `cosign verify`. Agents don't hand-edit `/opt/loom-gitops`, run images outside Compose, or read `secrets.env` values into comments.

---

## 4. Firewall & network

### 4.1 Find the public interface
```bash
EXT_IF=$(ip -o -4 route show to default | awk '{print $5; exit}')
echo "$EXT_IF"             # for example: eth0, ens3 or enp1s0
```

### 4.2 ufw rules (host INPUT)
Add the SSH rule **before** you enable ufw, or you'll lock yourself out.
```bash
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed

# SSH: board admin source IPs only (repeat for each admin IP/CIDR)
sudo ufw allow from 198.51.100.7/32 to any port 22 proto tcp comment 'ssh board-admin'
# ...plus the Paperclip egress IP, for loom-agent (§3.6). It was 167.254.58.3 as of 2026-09-27; confirm it with the board, since it may change.
sudo ufw allow from 167.254.58.3/32 to any port 22 proto tcp comment 'ssh paperclip-agents'
# sudo ufw allow from 2001:db8:abcd::/48 to any port 22 proto tcp comment 'ssh board-admin v6'

# Public services
sudo ufw allow 80/tcp   comment 'http (ACME + redirect, via Cloudflare)'
sudo ufw allow 443/tcp  comment 'https/wss (caddy, via Cloudflare)'
sudo ufw allow 4000/tcp comment 'telnet (loom, direct)'

sudo ufw logging low
sudo ufw --force enable
sudo ufw status verbose
```
Check SSH from a new terminal **before** you close the old one.
If admin IPs change often, use a VPN/Tailscale range as `ADMIN_SRC_IPS` rather than opening 22 to the world.

**`system.loommud.com` as built (board decision, OBI-106):** the admin and Paperclip egress IP is dynamic, so **22 stays open to Anywhere** (`sudo ufw allow 22/tcp`). It's protected by key-only auth, `AllowGroups sudo` and **fail2ban**. X4 in §9.4 is a documented exception. Install fail2ban like this:
```bash
sudo apt install -y fail2ban
sudo tee /etc/fail2ban/jail.d/loom-sshd.local >/dev/null <<'EOF'
[DEFAULT]
# board admin + Paperclip egress (dynamic; update if it changes)
ignoreip = 127.0.0.1/8 ::1 167.254.58.3
banaction = ufw
backend = systemd

[sshd]
enabled  = true
mode     = aggressive
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
bantime.maxtime   = 1w
EOF
sudo fail2ban-client -t && sudo systemctl enable --now fail2ban && sudo systemctl restart fail2ban
sudo fail2ban-client status sshd
```
If you get banned from a new IP, use the IONOS console: `sudo fail2ban-client set sshd unbanip <ip>`, then add the IP to `ignoreip`.

### 4.3 Docker bypasses ufw: fix it with `DOCKER-USER`
**The problem:** ports published by Docker (`ports:` in Compose) are DNAT-ed in the `nat` table and forwarded through the `FORWARD` chain. They never reach ufw's `INPUT` rules. So **any** published port is reachable from the internet, whatever `ufw status` says. Compose will publish only 80, 443 and 4000 (D-P1.14), but one wrong `ports:` line in a future PR (say `5432:5432`) would expose Postgres.

**The fix:** use Docker's `DOCKER-USER` chain, which Docker never flushes, to drop forwarded traffic from the public interface unless it's going to 80, 443 or 4000. Load it from ufw's `after.rules`, so it survives reboots and `ufw reload`:
```bash
EXT_IF=$(ip -o -4 route show to default | awk '{print $5; exit}')
for f in /etc/ufw/after.rules /etc/ufw/after6.rules; do
  sudo cp -n "$f" "$f.orig"
  sudo sed -i '/^# BEGIN LOOM DOCKER-USER/,/^# END LOOM DOCKER-USER/d' "$f"
  sudo tee -a "$f" >/dev/null <<EOF
# BEGIN LOOM DOCKER-USER
# Only 80/443/4000 may be forwarded from the public interface to containers.
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER ! -i ${EXT_IF} -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 80   --ctdir ORIGINAL -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 443  --ctdir ORIGINAL -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 4000 --ctdir ORIGINAL -j RETURN
-A DOCKER-USER -j DROP
COMMIT
# END LOOM DOCKER-USER
EOF
done
sudo ufw reload
sudo systemctl restart docker
sudo iptables  -S DOCKER-USER     # expect the 6 rules above, ending in "-j DROP"
sudo ip6tables -S DOCKER-USER
```
Notes:
- `--ctorigdstport` matches the port the client connected to, before DNAT rewrote it. That's why it's used instead of `--dport`.
- Container **outbound** traffic (arriving from `docker0`/`br-*`) and replies are unaffected.
- Docker-published IPv6 ports on IPv4-only Compose networks are served by `docker-proxy` and go through ufw `INPUT`, which already allows only 80/443/4000. **TBD-by-R6:** if R6 enables IPv6 on the Compose networks, the `after6.rules` block above covers it.
- The provider firewall/security group (§1.1) is the outer layer. Keep it matching.

**Prove it works** (host side):
```bash
sudo docker run -d --rm --name fwtest -p 4000:80 -p 8081:80 nginx:alpine
```
Then from your workstation:
```bash
nc -vz  -w 5 system.loommud.com 4000     # must SUCCEED (allowed)
nc -vz  -w 5 system.loommud.com 8081     # must FAIL/time out (the DOCKER-USER drop works)
```
Clean up on the host: `sudo docker rm -f fwtest && sudo docker image rm nginx:alpine`.

### 4.4 Outbound
Leave outbound open (`ufw default allow outgoing`). GitHub, GHCR, ACME and Azure are served from rotating CDN IPs, so pinning egress by IP is fragile and not worth the risk here. If your provider **does** filter egress, allow these:

| Destination | Port | Used by |
|---|---|---|
| `github.com`, `codeload.github.com` | 443 | `git fetch` of `loom-gitops`; `mudlib-sync` clone of `LoomMud/warp` |
| `api.github.com` | 443 | reconciler posts the `staging/reconcile` commit status |
| `ghcr.io`, `pkg-containers.githubusercontent.com` | 443 | pull `ghcr.io/loommud/loom` (and blobs) |
| `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | 443 | pull `caddy`, `postgres`, `alpine/git` support images |
| `fulcio.sigstore.dev`, `rekor.sigstore.dev`, `tuf-repo-cdn.sigstore.dev` | 443 | `cosign verify` (keyless, Sigstore) |
| `acme-v02.api.letsencrypt.org` (and `acme.zerossl.com`, Caddy's fallback CA) | 443 | origin TLS certificates |
| `<AZ_STORAGE_ACCOUNT>.blob.core.windows.net` | 443 | backups (Azure Blob) |
| `www.cloudflare.com` | 443 | refresh of Cloudflare IP ranges (§4.5), if you use it |
| `archive.ubuntu.com`, `security.ubuntu.com`, `download.docker.com` | 80/443 | OS and Docker updates |
| NTP/NTS servers (`ntp.ubuntu.com`, …) | UDP 123, TCP 4460 | time sync (chrony/NTS) |
| DNS resolvers | 53 | name resolution |

Quick outbound check from the host (set `SA` to your storage account name):
```bash
SA=loommudbackups
for u in https://github.com https://api.github.com https://ghcr.io/v2/ https://acme-v02.api.letsencrypt.org/directory https://rekor.sigstore.dev https://registry-1.docker.io/v2/ "https://$SA.blob.core.windows.net/"; do
  printf '%-55s ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 "$u"
done
# Any HTTP code (200/301/400/401/404) means it's reachable; 000 means blocked.
```

### 4.5 Limit 80/443 to Cloudflare (recommended)
`loommud.com` and `www` are proxied, so all legitimate web traffic arrives from Cloudflare's IP ranges. The origin IP is public anyway (through `system.loommud.com`), so without this step anyone can bypass Cloudflare by sending `Host: loommud.com` straight to the IP. This step closes 80/443 to everything except Cloudflare. Port **4000 (telnet) and 22 are not affected**. Telnet is never proxied (§5.3).

Let's Encrypt HTTP-01 validation still works, because it reaches the origin **through** Cloudflare.

Run on the host. The script replaces the §4.2 `80/tcp` and `443/tcp` rules, and inserts a Cloudflare-only filter for 80/443 into `DOCKER-USER` (Docker bypasses ufw, §4.3):
```bash
sudo tee /usr/local/sbin/loom-cloudflare-fw >/dev/null <<'SCRIPT'
#!/bin/sh
# Restrict inbound 80/443 (host + Docker-published) to Cloudflare's published ranges.
set -eu
EXT_IF=$(ip -o -4 route show to default | awk '{print $5; exit}')
V4=$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v4)
V6=$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v6)
[ -n "$V4" ] && [ -n "$V6" ] || { echo "empty Cloudflare IP list, aborting" >&2; exit 1; }

# 1. ufw (host INPUT): drop the open 80/443 rules, allow Cloudflare only
ufw --force delete allow 80/tcp  >/dev/null 2>&1 || true
ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
for cidr in $V4 $V6; do
  ufw allow proto tcp from "$cidr" to any port 80,443 comment 'cloudflare' >/dev/null
done

# 2. DOCKER-USER (forwarded to containers): 80/443 only from Cloudflare
for fam in 4 6; do
  f=/etc/ufw/after.rules; [ "$fam" = 6 ] && f=/etc/ufw/after6.rules
  list=$V4; [ "$fam" = 6 ] && list=$V6
  sed -i '/^# BEGIN LOOM CLOUDFLARE/,/^# END LOOM CLOUDFLARE/d' "$f"
  {
    echo "# BEGIN LOOM CLOUDFLARE"
    echo "*filter"
    echo ":LOOM-CF - [0:0]"
    echo "-F LOOM-CF"
    for cidr in $list; do echo "-A LOOM-CF -s $cidr -j RETURN"; done
    echo "-A LOOM-CF -j DROP"
    # Inserted at position 3: after the ESTABLISHED and non-public-interface RETURNs from §4.3,
    # before its 80/443/4000 RETURNs. Needs the §4.3 block to come earlier in the same file.
    echo "-I DOCKER-USER 3 -i $EXT_IF -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 443 -j LOOM-CF"
    echo "-I DOCKER-USER 3 -i $EXT_IF -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 80 -j LOOM-CF"
    echo "COMMIT"
    echo "# END LOOM CLOUDFLARE"
  } >> "$f"
done
ufw reload
SCRIPT
sudo chmod 0755 /usr/local/sbin/loom-cloudflare-fw
sudo /usr/local/sbin/loom-cloudflare-fw
sudo systemctl restart docker
sudo ufw status | grep -c cloudflare          # expect about 20+ rules
sudo iptables -S DOCKER-USER | head -5        # expect jumps to LOOM-CF before the 80/443 RETURNs
sudo iptables -S LOOM-CF | tail -2            # expect "... -j RETURN" then "-j DROP"
```
How it works: new connections to 80/443 on the public interface jump to `LOOM-CF`. That chain returns (on to the §4.3 allow rules) for Cloudflare sources and drops everything else.

Cloudflare rarely changes its ranges, but check monthly: re-run `sudo /usr/local/sbin/loom-cloudflare-fw && sudo systemctl restart docker`.

Check from a workstation (not through Cloudflare):
```bash
curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' --resolve loommud.com:443:PUBLIC_IPV4 https://loommud.com/   # must time out (000)
curl -sS -o /dev/null -w '%{http_code}\n' https://loommud.com/                                                    # through Cloudflare: works (after §9)
```
To undo: `sudo sed -i '/^# BEGIN LOOM CLOUDFLARE/,/^# END LOOM CLOUDFLARE/d' /etc/ufw/after.rules /etc/ufw/after6.rules`, delete the `cloudflare` ufw rules, re-add `ufw allow 80/tcp` and `ufw allow 443/tcp`, then `sudo ufw reload && sudo systemctl restart docker`.

Also restrict 80/443 to Cloudflare in the provider firewall (§1.1) if it supports it.

---

## 5. DNS & Cloudflare

### 5.1 Records (Cloudflare dashboard → `loommud.com` → DNS → Records)

| Type | Name | Content | Proxy status | Purpose |
|---|---|---|---|---|
| A | `system` | `PUBLIC_IPV4` | **DNS only** (grey cloud) | SSH (admins) and telnet :4000 (players): direct to the host |
| AAAA | `system` | `PUBLIC_IPV6` | **DNS only** | only if the host has working public IPv6 with 22/4000 open on v6 |
| A | `@` (`loommud.com`) | `PUBLIC_IPV4` | **Proxied** (orange cloud) | HTTPS / WSS web client, via Cloudflare |
| CNAME | `www` | `loommud.com` | **Proxied** | same, via Cloudflare |
| AAAA | `@` | `PUBLIC_IPV6` | Proxied | optional. Cloudflare serves IPv6 to visitors either way; only add this if the origin's v6 works on 80/443. |

TTL: *Auto*. `system` **must** stay DNS only. Cloudflare's proxy carries only HTTP(S) on a fixed port list (443, 80, 8443, …). It does not carry SSH or port 4000.

### 5.2 Cloudflare zone settings
- **SSL/TLS → Overview → encryption mode: Full (strict).** Cloudflare connects to the origin over HTTPS and checks the origin's certificate. Caddy gets a real Let's Encrypt certificate for `loommud.com` and `www.loommud.com` (§9). Until it does, the site shows Cloudflare error 526. That's expected before the bootstrap. Don't use *Flexible*: it sends traffic to the origin over plain HTTP and causes redirect loops with Caddy.
- **SSL/TLS → Edge Certificates → Always Use HTTPS: Off.** Caddy already redirects HTTP to HTTPS, and it leaves `/.well-known/acme-challenge/` on HTTP so Let's Encrypt can validate. Turning it on at the edge can break certificate issuance and renewal.
- **SSL/TLS → Edge Certificates → Minimum TLS version:** 1.2.
- **Network → WebSockets: On** (the default). The web client uses WSS.
- **Caching:** the default rules don't cache HTML or WebSocket traffic, so leave them. Don't add "Cache Everything" rules.
- **Security → Bots:** if you turn on *Bot Fight Mode*, check afterwards that the web client still connects (X10 in §9.4).

**Fallback if Let's Encrypt can't validate through Cloudflare:** create a **Cloudflare Origin CA** certificate (SSL/TLS → Origin Server) for `loommud.com, *.loommud.com`, and have Caddy use it instead of ACME. Origin CA certificates are trusted by Cloudflare only, which is fine because the public names are always proxied. This needs a Caddyfile change, so raise it on OBI-42 (**TBD-by-R6**).

### 5.3 Telnet goes to `system.loommud.com:4000`
Cloudflare can't proxy raw TCP on port 4000 without Spectrum (a paid add-on). So:
- players use **`telnet system.loommud.com 4000`**, straight to the host;
- `telnet loommud.com 4000` will **not** work (it resolves to Cloudflare).

If you'd rather give players a friendlier telnet name than `system`, add another **DNS only** record later (for example `play` → `PUBLIC_IPV4`). That's a board choice; it doesn't change anything on the host.

### 5.4 CAA
If `loommud.com` has **CAA** records, they must allow Let's Encrypt (for Caddy's origin certificate) as well as Cloudflare's edge CAs:
```bash
dig +short CAA loommud.com
# If there's output and no "letsencrypt.org", add:  loommud.com. CAA 0 issue "letsencrypt.org"
```
Cloudflare adds the CAA records it needs for its own edge certificates automatically.

### 5.5 Verify
Find the host's real public addresses (on the host):
```bash
curl -4 -s https://api.ipify.org; echo
curl -6 -s --max-time 5 https://api6.ipify.org; echo    # empty or an error = no public IPv6
```
From your workstation:
```bash
dig +short A system.loommud.com @1.1.1.1      # must equal PUBLIC_IPV4 (direct)
dig +short A system.loommud.com @8.8.8.8      # same
dig +short A loommud.com        @1.1.1.1      # must be Cloudflare IPs (104.x / 172.64–71.x), NOT PUBLIC_IPV4
dig +short A www.loommud.com    @1.1.1.1      # Cloudflare IPs
curl -sI http://loommud.com/ | grep -iE '^(server|cf-ray):'   # expect: server: cloudflare, cf-ray: …
```
Wait for these to return the right answers **before** running the bootstrap (§9). Caddy requests the origin certificate on first start.

---

## 6. Backup storage (Azure Blob)

What's required (D-P1.12, now on Azure): a private Azure Blob container, a credential that can **write, list and read in that container only** (no delete, no account admin), plus a lifecycle rule that deletes backups after about 90 days.

How it maps from the S3 design:

| S3 design | Azure |
|---|---|
| bucket | storage account `AZ_STORAGE_ACCOUNT` + container `AZ_CONTAINER` |
| bucket-scoped IAM key (put/list/get) | container **SAS token** with permissions `rcwl` (read, create, write, list; **no** `d` delete), tied to a **stored access policy** so it can be revoked |
| lifecycle rule | storage account **lifecycle management** policy scoped to the container |
| `rclone` S3 backend | `rclone` **azureblob** backend (`sas_url`) |

The storage account key has full control of the account. It is used **only** from the admin workstation in this section and **never** goes on the host.

Run all of this from an admin workstation with the Azure CLI (`az login`, then `az account set --subscription <id>`).

### 6.1 Create the storage account and container
```bash
AZ_RG=loom-backups-rg
AZ_REGION=westeurope              # <- your region
SA=loommudbackups                 # <- AZ_STORAGE_ACCOUNT (globally unique)
CT=loom-backups                   # <- AZ_CONTAINER

az group create -n "$AZ_RG" -l "$AZ_REGION"
az storage account create -n "$SA" -g "$AZ_RG" -l "$AZ_REGION" \
  --kind StorageV2 --sku Standard_LRS --access-tier Cool \
  --https-only true --min-tls-version TLS1_2 \
  --allow-blob-public-access false
# Keep deleted/overwritten backups recoverable for a while (protects against a compromised host overwriting blobs)
az storage account blob-service-properties update -g "$AZ_RG" --account-name "$SA" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 14

# Admin-only: the account key (stays on this workstation, in a shell variable)
SA_KEY=$(az storage account keys list -g "$AZ_RG" -n "$SA" --query '[0].value' -o tsv)
az storage container create --account-name "$SA" --account-key "$SA_KEY" -n "$CT" --public-access off
```
- `Standard_LRS` + `Cool` tier is cheapest for write-mostly backups. Use `Standard_ZRS` if you want zone redundancy. Backups are age-encrypted before upload; Azure also encrypts at rest by default.
- **Cool tier caveat:** Azure charges an early-deletion fee for blobs deleted within 30 days on Cool. With the 90-day rule that doesn't apply. If R6 later uses 15-day `daily/` expiry (§6.4 option a), switch the account to `--access-tier Hot`.

### 6.2 Container-scoped SAS token (write/list/read, no delete)
Create a **stored access policy** on the container, then a SAS token that references it. Deleting the policy revokes the token immediately, without rotating the account key.
```bash
EXPIRY=$(date -u -d '+1 year' +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -v+1y +%Y-%m-%dT%H:%MZ)   # GNU or macOS date
az storage container policy create --account-name "$SA" --account-key "$SA_KEY" \
  --container-name "$CT" --name loom-backup-writer \
  --permissions rcwl --expiry "$EXPIRY"
# Generate the SAS token (prints once; copy it straight into the password manager)
az storage container generate-sas --account-name "$SA" --account-key "$SA_KEY" \
  --name "$CT" --policy-name loom-backup-writer --https-only -o tsv
unset SA_KEY
```
- Permissions: `r` read, `c` create, `w` write, `l` list. No `d`, so the host can't delete backups. `w` does allow overwriting a blob, which is why §6.1 turns on versioning and soft delete: an overwritten backup's previous version is kept.
- **Put a calendar reminder** two weeks before `EXPIRY`. To renew: `az storage container policy update … --expiry <new date>` (the token keeps working, same value).
- **To revoke** (for example, after a leak): `az storage container policy delete --account-name "$SA" --account-key "$SA_KEY" --container-name "$CT" --name loom-backup-writer`, then create a new policy and token. Policy changes can take up to 30 seconds to apply.
- Keep the SAS token **only** in your password manager now, and in `secrets.env` in §9. R6's backup container uses it as an rclone `azureblob` remote with `sas_url = https://<SA>.blob.core.windows.net/<CT>?<SAS token>` (**TBD-by-R6:** exact variable names; see Appendix A).

### 6.3 Lifecycle rule (~90 days)
```bash
cat > lifecycle.json <<EOF
{
  "rules": [
    {
      "enabled": true,
      "name": "expire-after-90-days",
      "type": "Lifecycle",
      "definition": {
        "filters": { "blobTypes": ["blockBlob"], "prefixMatch": ["$CT/"] },
        "actions": {
          "baseBlob": { "delete": { "daysAfterModificationGreaterThan": 90 } },
          "version":  { "delete": { "daysAfterCreationGreaterThan": 30 } }
        }
      }
    }
  ]
}
EOF
az storage account management-policy create --account-name "$SA" -g "$AZ_RG" --policy @lifecycle.json
az storage account management-policy show   --account-name "$SA" -g "$AZ_RG" -o jsonc
```
Azure runs lifecycle policies about once a day, and a new policy can take up to 24–48 hours to start acting.

**TBD-by-R6: how retention is enforced.** R6 keeps 14 daily and 8 weekly backups. With a no-delete token, `rclone` can't prune old backups, so the options are:
- **(a) Recommended:** R6 writes to `daily/` and `weekly/` prefixes, and the board adds two more lifecycle rules (`prefixMatch: ["loom-backups/daily/"]` → delete after 15 days; `["loom-backups/weekly/"]` → delete after 60 days). The 90-day rule stays as the safety net. A compromised host can then never delete backups.
- **(b)** Add `d` to the stored access policy so that `rclone` prunes.

Until R6 confirms, apply only the 90-day rule. With small alpha dumps, 90 days of dailies costs very little.

### 6.4 Verify the token's scope (from a workstation, with the **SAS token**, not the account key)
```bash
read -rs SAS; echo                                 # paste the SAS token; not echoed or saved in history
echo ok > ok.txt
az storage blob upload   --account-name "$SA" -c "$CT" -n setup-check/ok.txt -f ok.txt --sas-token "$SAS" -o none && echo "put ok"   # must succeed
az storage blob list     --account-name "$SA" -c "$CT" --prefix setup-check/ --sas-token "$SAS" --query '[].name' -o tsv             # list: prints setup-check/ok.txt
az storage blob download --account-name "$SA" -c "$CT" -n setup-check/ok.txt -f ok-back.txt --sas-token "$SAS" -o none && cat ok-back.txt   # get: prints "ok"
az storage blob delete   --account-name "$SA" -c "$CT" -n setup-check/ok.txt --sas-token "$SAS"        # delete: must FAIL (AuthorizationPermissionMismatch)
az storage container list --account-name "$SA" --sas-token "$SAS"                                       # list containers: must FAIL
rm -f ok.txt ok-back.txt; unset SAS
```
(The leftover `setup-check/ok.txt` expires under the lifecycle rule.)

---

## 7. age keypair (offline)

The host **never** holds the private key. Backups are encrypted to the public key, and only the board can decrypt them (D-P1.12).

1. On an **offline or trusted admin workstation** (not the `loom` host), install `age` (`sudo apt install age` / `brew install age` / `winget install FiloSottile.age`), then:
   ```bash
   umask 077
   age-keygen -o loom-backup.agekey
   # prints:  Public key: age1…   <- this is the only value you post
   age-keygen -y loom-backup.agekey   # re-prints the public key at any time
   ```
2. Test a round trip:
   ```bash
   echo "restore-test" | age -r "$(age-keygen -y loom-backup.agekey)" | age -d -i loom-backup.agekey
   # expect: restore-test
   ```
3. **Store the private key** (the file with `AGE-SECRET-KEY-1…`):
   - in the board password manager (as a file attachment or secure note), **and**
   - one offline copy (an encrypted USB stick or a paper printout in a safe) held by a **second** board member.
   - Optional: wrap it with a passphrase, `age -p -o loom-backup.agekey.age loom-backup.agekey`, then store the `.age` file instead.
   - Then delete the plaintext from the workstation: `shred -u loom-backup.agekey` (on macOS, `rm -P`).
4. **Never** copy the private key to the host, a Paperclip comment, a GitHub issue, chat or a screenshot.
5. Post the `age1…` public key on OBI-56 (§11). R6 commits it to `loom-gitops` config, where it's public by design.

**TBD-by-R6:** restore-drill procedure with the real key. The recommended approach is to run `staging/restore.sh` from an admin workstation, or on the host with the key streamed on stdin and never written to disk. Follow the R6 runbook when it lands.

---

## 8. GitHub token & GHCR

### 8.1 Fine-grained token for commit statuses
Pre-requisite (org owner, once): **LoomMud org → Settings → Personal access tokens → Settings**: allow fine-grained personal access tokens. If "require administrator approval" is on, approve the token after step 2.

1. As a board member: **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.**
   - **Token name:** `loom-reconcile-status`
   - **Resource owner:** `LoomMud`
   - **Expiration:** the maximum your org allows (for example 366 days). **Put a calendar reminder** two weeks before it expires. When it expires, the reconciler's status posts fail and `staging/reconcile` stops updating.
   - **Repository access:** *Only select repositories* → `LoomMud/loom-gitops`
   - **Permissions → Repository permissions:** **Commit statuses: Read and write**. Leave everything else as *No access*. (*Metadata: Read-only* is added automatically and is mandatory.)
   - No account permissions.
2. Copy the token (`github_pat_…`) straight into the password manager. It goes into `secrets.env` in §9.
3. Verify (on any machine; the token isn't echoed or saved in history):
   ```bash
   read -rs GH_STATUS_TOKEN; echo
   SHA=$(curl -fsS https://api.github.com/repos/LoomMud/loom-gitops/commits/main | jq -r .sha)
   # write check: posts a harmless status on loom-gitops main
   curl -fsS -X POST \
     -H "Authorization: Bearer $GH_STATUS_TOKEN" -H "Accept: application/vnd.github+json" \
     https://api.github.com/repos/LoomMud/loom-gitops/statuses/$SHA \
     -d '{"state":"success","context":"loom/setup-check","description":"board token check"}' | jq -r '.state, .context'
   # expect: success / loom/setup-check
   unset GH_STATUS_TOKEN
   ```
   On the token's page, check that the permissions list shows only *Commit statuses: Read and write* and *Metadata: Read-only*.

Statuses show the token owner's GitHub account as the creator. That's expected. (A GitHub App or machine user can replace the PAT later; it's out of scope for Phase 1.)

### 8.1b Fine-grained token for alerting (OBI-175/P2-O4)
A second, separately-scoped token: `staging/alerts.sh` needs to read commit
statuses (to check `staging/reconcile`) and to open/comment/close issues
(to deliver an alert), but never needs to *write* a commit status -- least
privilege keeps this out of `GITHUB_STATUS_TOKEN`, whose write access is
scoped the other way around.

1. Same org-owner pre-requisite as §8.1 (already done once that token
   exists). As a board member: **GitHub → Settings → Developer settings →
   Personal access tokens → Fine-grained tokens → Generate new token.**
   - **Token name:** `loom-alerts`
   - **Resource owner:** `LoomMud`
   - **Expiration:** same policy as §8.1 -- put a calendar reminder two
     weeks out. When it expires, `loom-alerts.timer` keeps running and
     logging every check (see `staging/alerts.sh`), it just stops
     delivering anything.
   - **Repository access:** *Only select repositories* → `LoomMud/loom-gitops`
   - **Permissions → Repository permissions:** **Commit statuses:
     Read-only**, **Issues: Read and write**. Leave everything else as
     *No access*. (*Metadata: Read-only* is added automatically.)
   - No account permissions.
2. Copy the token into the password manager. It goes into `secrets.env`
   as `GITHUB_ALERTS_TOKEN` in §9.
3. Verify (on any machine; not echoed or saved in history):
   ```bash
   read -rs GH_ALERTS_TOKEN; echo
   # read check: commit statuses on a public repo don't even need auth,
   # but confirm the token itself is valid and scoped right:
   curl -fsS -H "Authorization: Bearer $GH_ALERTS_TOKEN" -H "Accept: application/vnd.github+json" \
     https://api.github.com/repos/LoomMud/loom-gitops/commits/main/statuses | jq -r '.[0].state // "(no statuses yet)"'
   # write check: opens + immediately closes a throwaway issue
   NUM=$(curl -fsS -X POST \
     -H "Authorization: Bearer $GH_ALERTS_TOKEN" -H "Accept: application/vnd.github+json" \
     https://api.github.com/repos/LoomMud/loom-gitops/issues \
     -d '{"title":"loom-alerts token check","body":"safe to close/delete","labels":["alert"]}' | jq -r '.number')
   curl -fsS -X PATCH -H "Authorization: Bearer $GH_ALERTS_TOKEN" -H "Accept: application/vnd.github+json" \
     https://api.github.com/repos/LoomMud/loom-gitops/issues/$NUM -d '{"state":"closed"}' >/dev/null
   echo "opened and closed #$NUM"
   unset GH_ALERTS_TOKEN
   ```
   On the token's page, check that the permissions list shows only
   *Commit statuses: Read-only*, *Issues: Read and write* and
   *Metadata: Read-only*.

### 8.2 GHCR: make `ghcr.io/loommud/loom` public
> **Timing:** the package only exists after the first R5 release pushes an image (OBI-29). As of 2026-09-26 it doesn't exist yet (`Package not found`). Do this step as soon as the first image is published. Gandalf/Legolas will say when on OBI-56.

1. Org owner, once: **LoomMud org → Settings → Packages → Package creation**: make sure **Public** is allowed.
2. **github.com/orgs/LoomMud/packages/container/package/loom → Package settings → Danger Zone → Change visibility → Public** (type the package name to confirm).
3. Verify anonymous pull (from anywhere):
   ```bash
   curl -s "https://ghcr.io/token?scope=repository:loommud/loom:pull" | jq -r '.token // .errors[0].code'
   # public: prints a long token string.   Not public / missing: prints DENIED
   ```
   On the host: `sudo docker logout ghcr.io; sudo docker pull ghcr.io/loommud/loom:<tag-from-OBI-29>` must succeed.

**Fallback (only if the package can't be public):** a **classic** PAT (fine-grained PATs don't work with GHCR) with only the `read:packages` scope and an expiry date, owned by a board member with read access to the package. Log in as the service user so the reconciler's `docker compose pull` uses it:
```bash
read -rs GHCR_TOKEN; echo
echo "$GHCR_TOKEN" | sudo -u loom env HOME=/var/lib/loom \
  docker login ghcr.io -u <github-username> --password-stdin
unset GHCR_TOKEN
sudo chmod 600 /var/lib/loom/.docker/config.json
```
**TBD-by-R6:** R6 may instead read a `GHCR_TOKEN` variable from `secrets.env` and log in during reconcile. If `secrets.env.example` has such a variable, put the token there and skip the `docker login`.

---

## 9. Bootstrap & verification (OBI-56 item 8)

> Do this **when OBI-42 reaches its evidence step** and `staging/bootstrap.sh`, `staging/secrets.env.example` and the runbook exist on `loom-gitops` `main`. Until then, sections 1–8 are complete on their own.

### 9.1 Update the clone
```bash
sudo -u loom git -C /opt/loom-gitops pull --ff-only
ls -l /opt/loom-gitops/staging/        # expect: bootstrap.sh, secrets.env.example, compose.yaml, images.env, runbook …
```

### 9.2 Fill in `secrets.env`
```bash
# Copy the template into place, keeping owner/mode
sudo install -o root -g loom -m 0640 /opt/loom-gitops/staging/secrets.env.example /etc/loom/secrets.env
# Generate the Postgres password (hex, so it needs no URL escaping in DATABASE_URL). Copy it into the password manager.
openssl rand -hex 24
# Edit in place. sudoedit keeps owner/mode and leaves no copy in shell history.
sudoedit /etc/loom/secrets.env
sudo stat -c '%U:%G %a' /etc/loom/secrets.env      # expect: root:loom 640
```
Expected contents: `NAME=value`, one per line, no spaces around `=`.

**On `system.loommud.com` this is already done (OBI-106), but needs an update (OBI-130).** The file has the `secrets.env.example` layout from OBI-106, with a single `POSTGRES_PASSWORD` (48 hex characters). **OBI-130 (DB role separation) replaced that one variable with three** -- `POSTGRES_SUPERUSER_PASSWORD`, `LOOM_OWNER_PASSWORD`, `LOOM_APP_PASSWORD` -- so a board admin must `sudoedit /etc/loom/secrets.env` and: rename the existing `POSTGRES_PASSWORD` line's value to `POSTGRES_SUPERUSER_PASSWORD` (or generate a fresh one), then add `LOOM_OWNER_PASSWORD` and `LOOM_APP_PASSWORD`, each its own `openssl rand -hex 24`. This is safe to do before bootstrap (§9.3): the `pgdata` volume doesn't exist yet, so there is no existing schema/superuser to reconcile against. **Agents do not have host access for this step** (no `loom-agent` SSH governance ticket yet, per this doc's charter) -- a board admin must make the edit. The GitHub token step is unchanged: run `sudoedit /etc/loom/secrets.env` and replace `REPLACE_WITH_GITHUB_PAT` on the `GITHUB_STATUS_TOKEN=…` line with the §8.1 token. Leave the backup lines commented out until §6 and §7 are done.

The **variable names** are fixed in `staging/secrets.env.example` (CTO decision, OBI-106; R6 must use them). By design (D-P1.13, updated for Azure) they cover:
- the Postgres password (from `openssl` above);
- the Azure storage account name, container name and **container SAS token** (§6.2). Never the storage account key;
- the GitHub commit-status token (§8.1);
- a GHCR token, only if §8.2 fell back and R6 reads it from this file.

The **age public key is not a secret** and doesn't go here. R6 keeps it in repo config. No Cloudflare credential is needed on the host (unless the Origin CA / DNS-01 fallback in §5.2 is chosen).

Don't `cat` the file on a shared screen, and don't paste its contents anywhere.

**B3/OBI-192 adds two more secrets, but not here:** the `loom-warp-propose` GitHub App private key and the webhook HMAC secret are files, not `secrets.env` lines (D-B3.11/D-B3.12) -- see `RUNBOOK.md` §12 for the exact install commands and modes once Q-P2.3 provisions the real App. Until then the placeholders in `staging/secrets/*.example` are enough to boot: `loom-git` runs with push/`propose` disabled and logs that once at boot.

### 9.3 Run the bootstrap
```bash
sudo /opt/loom-gitops/staging/bootstrap.sh
```
**TBD-by-R6:** exact invocation (whether it must run as root via `sudo`, and any flags) and what it prints. By design it installs the reconciler systemd service + timer (every 2 min, `User=loom`), checks `/etc/loom/secrets.env` and its modes, and runs the first reconcile: fast-forward, `cosign verify`, `docker compose pull && up -d`, wait for healthy, and post the `staging/reconcile` status. Caddy serves `loommud.com` and `www.loommud.com` (**TBD-by-R6:** Caddyfile hostnames and Cloudflare `trusted_proxies`, see Appendix A). Follow the R6 runbook if it differs.

### 9.4 Verification checklist
Tick every row. Rows marked (TBD-by-R6) use unit or route names that R6 fixes.

**On the host**

| # | Check | Command | Expect |
|---|---|---|---|
| H1 | Docker version | `sudo docker info --format '{{.ServerVersion}}'` | ≥ 24 |
| H2 | Compose v2 | `docker compose version` | v2+ |
| H3 | Docker at boot | `systemctl is-enabled docker; systemctl is-active docker` | `enabled` / `active` |
| H4 | Firewall | `sudo ufw status verbose` | deny incoming; 4000 open; 80/443 open (Cloudflare ranges only if §4.5 applied); 22 only from admin IPs |
| H5 | Docker bypass closed | `sudo iptables -S DOCKER-USER` | the §4.3 rules (plus §4.5 `LOOM-CF` jumps), ending in `-j DROP` |
| H6 | Listening ports | `sudo ss -tlnp` | public: 22, 80, 443, 4000 only (5432/8080/9090/3000 absent or bound to container networks) |
| H7 | Secrets file | `sudo stat -c '%U:%G %a' /etc/loom /etc/loom/secrets.env` | `root:loom 750` / `root:loom 640` |
| H8 | Containers healthy | `sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'` | `loom`, `caddy`, `postgres` `Up … (healthy)`; `mudlib-sync` exited 0 |
| H9 | Reconciler timer (TBD-by-R6: unit name) | `systemctl list-timers --all \| grep -i loom` | next run within 2 min |
| H10 | Reconciler log (TBD-by-R6) | `journalctl -u <reconcile-unit> -n 50 --no-pager` | cosign verified, compose up, status posted |
| H11 | Time sync | `timedatectl status` | synchronized: yes |
| H12 | Unattended upgrades | `systemctl is-active unattended-upgrades` | `active` |
| H13 | Hostname | `hostnamectl --static` | `loom` |
| H14 | Origin certificate | `echo \| openssl s_client -connect 127.0.0.1:443 -servername loommud.com 2>/dev/null \| openssl x509 -noout -issuer -subject -ext subjectAltName -dates` | issuer Let's Encrypt (or ZeroSSL, or Cloudflare Origin CA if the §5.2 fallback is used); SAN includes `loommud.com` and `www.loommud.com`; valid dates |

**From an admin workstation (outside)**

| # | Check | Command | Expect |
|---|---|---|---|
| X1 | DNS | `dig +short A system.loommud.com @1.1.1.1; dig +short A loommud.com @1.1.1.1` | `PUBLIC_IPV4`; then Cloudflare IPs (not `PUBLIC_IPV4`) |
| X2 | Open ports | `nc -vz -w 5 system.loommud.com 4000; for p in 80 443; do nc -vz -w 5 loommud.com $p; done` | all succeed |
| X3 | Closed ports | `for p in 5432 8080 9090 3000 2375; do nc -vz -w 5 system.loommud.com $p; done` | all fail/time out |
| X4 | SSH restricted | `nc -vz -w 5 system.loommud.com 22` from a **non-admin** network (for example a phone hotspot) | fails/times out. **Exception on `system.loommud.com`:** 22 stays open by board decision (dynamic IP); instead check `sudo fail2ban-client status sshd` shows the jail active. |
| X5 | HTTP→HTTPS | `curl -sSI http://loommud.com/ \| grep -iE '^(HTTP\|location\|server)'` | `308`/`301` to `https://loommud.com/…`; `server: cloudflare` |
| X6 | Edge TLS + Full (strict) works | `curl -sS -o /dev/null -w '%{http_code}\n' https://loommud.com/; curl -sS -o /dev/null -w '%{http_code}\n' https://www.loommud.com/` | `200` (or `301` www→apex), **not** `526`/`525`/`521` |
| X7 | Proxied | `curl -sI https://loommud.com/ \| grep -i cf-ray` | a `cf-ray:` header |
| X8 | Metrics not public | `curl -s -o /dev/null -w '%{http_code}\n' https://loommud.com/metrics` | `403` or `404`, **not** `200` |
| X9 | Telnet | `telnet system.loommud.com 4000` | Loom banner / login prompt (quit with `Ctrl-]` then `quit`) |
| X10 | Web client | open `https://loommud.com/` in a browser | web client loads and connects (WSS through Cloudflare) |
| X11 | Origin not reachable around Cloudflare (if §4.5 applied) | `curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' --resolve loommud.com:443:PUBLIC_IPV4 https://loommud.com/` | `000` (timeout) |
| X12 | Reconcile status | `gh api repos/LoomMud/loom-gitops/commits/main/statuses --jq '[.[] \| select(.context=="staging/reconcile")][0] \| .state + " " + .description'` | `success …` |
| X13 | Backups (after the first nightly run; TBD-by-R6 for a manual trigger) | `az storage blob list --account-name <SA> -c loom-backups --sas-token "$SAS" --query '[].name' -o tsv` | timestamped `*.age` blobs |

When every row passes, comment on OBI-56 (hostnames/IP only, see §11) that the bootstrap is done. Legolas will then run the OBI-42 evidence (character creation, live `update`, image-bump rollout).

---

## 10. Security reminders

- **Never post secrets** in Paperclip comments, question cards, GitHub issues/PRs, chat or screenshots. That covers the Azure SAS token and storage account key, GitHub/GHCR tokens, the Postgres password, Cloudflare credentials, the age private key, and the contents of `secrets.env`.
- **The only values that belong on OBI-56:** the hostnames (`system.loommud.com`, `loommud.com`, `www.loommud.com`), the public IP and the age **public** key (`age1…`).
- Secrets live in exactly two places: `/etc/loom/secrets.env` (`root:loom 0640`) on the host, and the board password manager. The age private key lives **only** offline (§7). The Azure storage account key never leaves the admin workstation / Azure portal.
- Type secrets with `read -rs` or `sudoedit`, never as command-line arguments (those land in shell history and `ps`).
- **If something leaks:** revoke it immediately (GitHub token page / delete the Azure stored access policy, §6.2 / rotate the Postgres password with `ALTER USER`, then update `secrets.env`), then tell Gandalf on OBI-56 *that* a rotation happened. Don't include the value.
- **Expiry reminders:** the GitHub token, the Azure SAS stored access policy, and the GHCR token (if used).
- Keep `system.loommud.com` **DNS only**. Turning its proxy on breaks SSH and telnet.
- **Don't** add people to the `docker` group, open extra ports, or edit `/opt/loom-gitops` by hand. Changes go through `loom-gitops` PRs.
- **Agent access is limited to one SSH key for `loom-agent` (§3.6).** Agents have no Cloudflare, Azure or GitHub-token access, and they never ask for secrets in comments. If a secret is needed on the host, a board member puts it there over their own SSH session, or creates a Paperclip secret. If anyone (human or agent) asks for a credential in a comment, decline. To cut agents off, delete the `authorized_keys` line (§3.6).

---

## 11. What to post on OBI-56

When sections 1–8 are done, post a comment like this (and/or answer the question card):
```text
Loom host provisioned (OBI-56 items 1–7).
- Machine: loom
- Direct (DNS only): system.loommud.com   (SSH admins, telnet :4000)
- Proxied (Cloudflare, Full strict): loommud.com, www.loommud.com
- Public IP: <PUBLIC_IPV4>   (IPv6: <PUBLIC_IPV6 or "none">)
- age public key: age1…
- GHCR: public | fallback read:packages token installed on host | pending first R5 image
- Backups: Azure Blob container created, SAS (rcwl, no delete) + 90-day lifecycle (no secrets)
- Item 8 (bootstrap): waiting for R6 runbook
```
Nothing else. No keys, tokens, passwords or `secrets.env` contents.

---

## Appendix A: open items for R6 (OBI-42)

| # | Item | Guide's working assumption |
|---|---|---|
| R6-1 | `bootstrap.sh` invocation, run-as user, flags | `sudo /opt/loom-gitops/staging/bootstrap.sh` |
| R6-2 | Exact `secrets.env` variable names | **Updated (OBI-130, supersedes OBI-106's single `POSTGRES_PASSWORD`; OBI-175 adds `GITHUB_ALERTS_TOKEN`):** `POSTGRES_SUPERUSER_PASSWORD`, `LOOM_OWNER_PASSWORD`, `LOOM_APP_PASSWORD`, `GITHUB_STATUS_TOKEN`, `GITHUB_ALERTS_TOKEN`, `AZURE_STORAGE_ACCOUNT`, `AZURE_STORAGE_CONTAINER`, `AZURE_STORAGE_SAS_TOKEN`, optional `GHCR_TOKEN` (see `staging/secrets.env.example`). If R6 needs a further rename, change the example file and the host file in the same PR/run. |
| R6-3 | Reconciler unit user, paths and names | `User=loom`; `/etc/loom/secrets.env` `root:loom 0640`, dir `/etc/loom` `0750` (CTO decision, supersedes D-P1.13's "root 0600" and the earlier `loom-staging` names) |
| R6-4 | Clone path | `/opt/loom-gitops`, owned by `loom` |
| R6-5 | cosign: host package or container | host `cosign` installed from Ubuntu universe either way |
| R6-6 | Backup retention with a no-delete token | recommend `daily/` + `weekly/` prefixes with lifecycle rules; 90-day catch-all |
| R6-7 | GHCR fallback mechanism | `docker login` as `loom`, or `GHCR_TOKEN` in `secrets.env` |
| R6-8 | Backup schedule vs 04:30 UTC reboot window | backup must not overlap 04:30 UTC |
| R6-9 | Manual first-backup trigger and real-key restore drill | runbook |
| R6-10 | IPv6 on Compose networks | off (the `after6.rules` block covers it if turned on) |
| R6-11 | Extra host prerequisites checked by `bootstrap.sh` | none beyond §2.3 |
| R6-12 | **Backup target is Azure Blob, not S3** (supersedes D-P1.12's S3 wording) | backup container uses the rclone `azureblob` backend with a container `sas_url`, `no_check_container = true` (the SAS can't create/inspect containers), and never deletes |
| R6-13 | **Caddy behind Cloudflare** | site addresses `loommud.com` + `www.loommud.com` (www → apex redirect or both served); ACME HTTP-01 (works through the proxy); `trusted_proxies` set to Cloudflare ranges so logs and rate limits see real client IPs; Origin CA certificate only as the §5.2 fallback |
| R6-14 | **Advertised telnet address** | `system.loommud.com:4000` (Cloudflare can't proxy 4000); any MOTD/web-client text that shows a telnet address must use it |

## Appendix B: troubleshooting

- **Locked out of SSH:** use the provider's web/serial console, then `sudo ufw allow from <your-ip> to any port 22 proto tcp`, or `sudo ufw disable` temporarily.
- **Agent SSH (`loom-agent`) times out, but admin SSH works:** the Paperclip egress IP has probably changed. Ask an agent to post its current egress IP (`curl -s https://ifconfig.me`), then `sudo ufw allow from <new-ip>/32 to any port 22 proto tcp comment 'ssh paperclip-agents'` and delete the old rule (`sudo ufw status numbered`, then `sudo ufw delete <n>`).
- **Agent SSH gives `Permission denied (publickey)`:** check that `loom-agent` is in the `sudo` group (`id loom-agent`), because `AllowGroups sudo` applies (§3.6). Then check the `authorized_keys` line and its modes.
- **SSH or telnet to `system.loommud.com` hangs:** check that the `system` record is **DNS only** (grey cloud). `dig +short system.loommud.com` must return `PUBLIC_IPV4`, not a Cloudflare IP.
- **Cloudflare error 526 (invalid origin certificate):** Caddy hasn't got its certificate yet. Check DNS (X1), that 80 reaches the origin through Cloudflare (X2), that **Always Use HTTPS** is off (§5.2), and CAA (§5.4). Then `sudo docker logs caddy 2>&1 | grep -i acme`. Let's Encrypt rate-limits repeated failures, so fix the cause before restarting in a loop. If validation through Cloudflare keeps failing, use the Origin CA fallback (§5.2).
- **Cloudflare error 521/522 (origin down/unreachable):** Caddy isn't running, or §4.5 blocked Cloudflare (re-run `loom-cloudflare-fw`; check that `curl https://www.cloudflare.com/ips-v4` returns a list).
- **Redirect loop on `loommud.com`:** the Cloudflare SSL mode is *Flexible*. Set it to **Full (strict)** (§5.2).
- **`docker compose pull` denied on `ghcr.io/loommud/loom`:** the package isn't public yet (§8.2), or the fallback login is missing or expired.
- **`staging/reconcile` status missing or failed with 401/403:** the status token has expired or lacks *Commit statuses: write* on `loom-gitops` (§8.1).
- **Backups fail with `AuthenticationFailed` / `AuthorizationPermissionMismatch`:** the SAS stored access policy has expired or was deleted, or lacks `c`/`w`/`l` (§6.2). Update the policy expiry; the token value stays the same.
- **Reconcile blocked by "local changes":** someone edited `/opt/loom-gitops`. Run `sudo -u loom git -C /opt/loom-gitops status`, then restore with `sudo -u loom git -C /opt/loom-gitops checkout -- . && sudo -u loom git -C /opt/loom-gitops clean -fd` (this discards local changes; they belong in a PR).
