<!--
SPDX-FileCopyrightText: 2026 Oberfield
SPDX-License-Identifier: AGPL-3.0-only
-->

# Loom staging host: board setup guide (Ubuntu 26.04 LTS)

**Audience:** Oberfield board admins provisioning the Docker Compose staging host requested in OBI-56.
**Target:** Ubuntu Server **26.04 LTS "Resolute Raccoon"**, x86_64 (amd64).
**Design reference:** OBI-8 plan r4 §3.4 (decisions D-P1.7 to D-P1.14). Stack implementation: R6 / OBI-42 (Legolas).
**Time:** about 60–90 min for sections 1–8, plus about 15 min for section 9 (after R6 ships `staging/bootstrap.sh`).

> **Golden rule.** The only things that ever go into a Paperclip comment are the **hostname**, the **public IP** and the **age public key** (`age1…`). Every other value in this guide (bucket key, GitHub tokens, Postgres password, age *private* key) goes into `/etc/loom-staging/secrets.env` on the host and/or the board password manager, and nowhere else. See §10.

Items marked **TBD-by-R6** depend on files R6 (OBI-42) has not shipped yet. Do not guess them. Skip that step until the repo has the file, or ask on OBI-42.

---

## Map: OBI-56 items → sections

| OBI-56 item | Section(s) |
|---|---|
| 1. Host: VM, Docker ≥ 24 + Compose v2, systemd, git, Docker at boot, outbound HTTPS | §1 Base OS, §2 Packages, §3 Users & permissions, §4.4 Outbound |
| 2. DNS hostname with A/AAAA | §5 DNS |
| 3. Firewall: 4000/80/443 in, SSH for admins only, rest closed | §3.2 SSH hardening, §4 Firewall |
| 4. Backup bucket, scoped key, ~90-day lifecycle | §6 Backup bucket |
| 5. age keypair, private key offline, post public key | §7 age keypair |
| 6. GitHub fine-grained token (commit statuses only) | §8.1 GitHub token |
| 7. GHCR public (fallback `read:packages` token) | §8.2 GHCR |
| 8. One-time bootstrap | §9 Bootstrap & verification |

Suggested order: §0 → §1 → §2 → §3 → §4 → §5, with §6, §7 and §8 done in parallel from an admin workstation. §9 comes later, when OBI-42 reaches its evidence step.

---

## 0. Before you start

### 0.1 Values sheet

Fill this in before you start (in your password manager or on paper, **not** in Paperclip). The shell snippets below use these names.

| Name | Example | Secret? |
|---|---|---|
| `DOMAIN` | `example.org` | no |
| `STAGING_FQDN` | `staging.example.org` | no (post on OBI-56) |
| `PUBLIC_IPV4` | `203.0.113.10` | no (post on OBI-56) |
| `PUBLIC_IPV6` | `2001:db8::10`, or *none* | no |
| `ADMIN_USER` | `alice` (one per board admin) | no |
| `ADMIN_SRC_IPS` | `198.51.100.7/32` (board admins' public IPs) | keep private, not secret |
| `BUCKET` | `loom-staging-backups` | no |
| `S3_ENDPOINT` / `S3_REGION` | `https://s3.eu-central-1.amazonaws.com` / `eu-central-1` | no |
| Bucket access key ID + secret | … | **SECRET** |
| GitHub fine-grained token (statuses) | `github_pat_…` | **SECRET** |
| GHCR `read:packages` token (fallback only) | `ghp_…` | **SECRET** |
| Postgres password | generated in §9 | **SECRET** |
| age private key | `AGE-SECRET-KEY-1…` | **SECRET, offline only, never on the host** |
| age public key | `age1…` | no (post on OBI-56) |

### 0.2 What you need
- A cloud/VPS account (any provider with Ubuntu 26.04 images) or a hypervisor.
- DNS control for `DOMAIN`.
- An S3-compatible object store account (AWS S3, Backblaze B2, Cloudflare R2, Wasabi, MinIO, …), ideally **a different provider/account from the VM**, so that losing the host account doesn't also lose the backups.
- An SSH key pair on each admin's workstation (`ssh-keygen -t ed25519` if you don't have one).
- Owner/admin rights on the `LoomMud` GitHub org (for the token policy and GHCR visibility).
- `age` on an offline or trusted workstation (§7).

---

## 1. Base OS

### 1.1 Create the VM
- **Image:** Ubuntu Server 26.04 LTS, amd64 (the minimal or cloud image is fine).
- **Size:** at least **2 vCPU / 4 GB RAM / 40 GB SSD**. Use one disk; no extra volumes are needed (Docker named volumes live under `/var/lib/docker`).
- **Network:** a static public IPv4 (reserved/elastic IP). IPv6 is optional; see §5 before you publish an AAAA record.
- **Provider firewall / security group** (if the provider has one): allow inbound TCP 22 from `ADMIN_SRC_IPS` only, and TCP 80, 443 and 4000 from anywhere. Deny everything else. This is a second layer on top of ufw (§4).
- **SSH key:** inject the first admin's public key at creation (cloud-init). Most images create a default `ubuntu` user with it.

SSH in as the default user (for example `ssh ubuntu@PUBLIC_IPV4`). Everything below runs on the host unless it says otherwise.

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
sudo hostnamectl set-hostname loom-staging
# Stop cloud-init from resetting it on reboot
echo 'preserve_hostname: true' | sudo tee /etc/cloud/cloud.cfg.d/99-loom-hostname.cfg
# Make sure the name resolves locally
grep -q 'loom-staging' /etc/hosts || echo '127.0.1.1 loom-staging' | sudo tee -a /etc/hosts
hostnamectl
```
(The OS hostname is internal. The public name is `STAGING_FQDN` in DNS, §5.)

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
| `jq`, `curl` | reconciler posts the GitHub commit status; verification commands |
| `openssl` | generates the Postgres password; TLS checks |
| `dnsutils`, `netcat-openbsd`, `telnet` | DNS, port and telnet verification (§5, §9) |
| `cosign` | the reconciler verifies image signatures before deploying (D-P1.8). Ubuntu 26.04 universe ships cosign 2.x. **TBD-by-R6:** R6 may run cosign from a pinned container instead. Installing the package is harmless either way. |

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
# Only sudo-group accounts (the board admins) may log in over SSH
AllowGroups sudo
EOF
sudo sshd -t && sudo systemctl restart ssh
# Check the effective settings
sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowgroups) '
# expect: permitrootlogin no / passwordauthentication no / kbdinteractiveauthentication no / allowgroups sudo
sudo passwd -l root        # lock the root password (it's normally locked already)
```
Check from your workstation, in a **new** session:
```bash
ssh ADMIN_USER@PUBLIC_IPV4                                                    # works (key)
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password ADMIN_USER@PUBLIC_IPV4   # must fail: "Permission denied (publickey)"
ssh root@PUBLIC_IPV4                                                          # must fail
```
Once your named admin works, disable the image's default user: `sudo usermod -L -s /usr/sbin/nologin ubuntu && sudo gpasswd -d ubuntu sudo`. To remove it completely, use `sudo deluser --remove-home ubuntu`.

(SSH source-IP restriction is done in the firewall, §4.2.)

### 3.3 Service user for Loom staging
One dedicated **system** account, with no login shell and no password. It owns the `loom-gitops` clone and runs the reconciler.
```bash
sudo useradd --system --user-group \
  --home-dir /var/lib/loom-staging --create-home \
  --shell /usr/sbin/nologin \
  --comment "Loom staging reconciler" loom-staging
sudo usermod -aG docker loom-staging
id loom-staging            # expect: groups include loom-staging and docker
```

> **Caveat: `docker` group = root.** Any member of the `docker` group can start a privileged container that mounts `/` and so gets full root on the host. `loom-staging` needs this, because the reconciler runs `docker compose`. The account is safe only because:
> - it has no password and no login shell, and SSH is limited to the `sudo` group (§3.2);
> - nothing agent-controlled can reach it. Agents influence the host only through reviewed PRs to `loom-gitops`, and every image digest is cosign-verified before it runs (D-P1.8);
> - admins do **not** join `docker`. They use `sudo docker`, so root-level actions stay explicit and logged by sudo.
>
> Rootless Docker was considered and rejected for Phase 1: it complicates binding ports 80/443, plus systemd user sessions and reconciler ergonomics. This will be revisited with the Phase 2+ Flux move.

### 3.4 Secrets directory and file
```bash
sudo install -d -o root -g loom-staging -m 0750 /etc/loom-staging
# Empty placeholder with the right owner/mode. It's filled in during §9 from secrets.env.example.
sudo install -o root -g loom-staging -m 0640 /dev/null /etc/loom-staging/secrets.env
sudo stat -c '%n %U:%G %a' /etc/loom-staging /etc/loom-staging/secrets.env
# expect: /etc/loom-staging root:loom-staging 750
#         /etc/loom-staging/secrets.env root:loom-staging 640
```
Why `root:loom-staging 0640`: root owns the file, so the service account can **read** it (Compose reads `env_file` on the client side) but can't change it. Nobody else can read it.

**Note for R6 (CTO decision, supersedes "root, 0600" in D-P1.13):** the reconciler systemd unit runs as `User=loom-staging`, so the file is `root:loom-staging 0640` and the directory is `root:loom-staging 0750`. If `bootstrap.sh` enforces modes, it must enforce these.

### 3.5 `loom-gitops` clone location
`LoomMud/loom-gitops` is a **public** repo, so the clone needs no credentials.
```bash
sudo install -d -o loom-staging -g loom-staging -m 0755 /opt/loom-gitops
sudo -u loom-staging git clone https://github.com/LoomMud/loom-gitops.git /opt/loom-gitops
# Let root/admins run read-only git commands in the service-owned clone without "dubious ownership" errors
sudo git config --system --add safe.directory /opt/loom-gitops
sudo -u loom-staging git -C /opt/loom-gitops log --oneline -1
```
- **Clone path:** `/opt/loom-gitops`, owned by `loom-staging`. Only the reconciler writes to it (fast-forwarding `main`).
- **Never edit files in this clone by hand.** Changes go through PRs. The reconciler fast-forwards, and local edits would block it.
- **TBD-by-R6:** if `bootstrap.sh` expects a different clone path, follow the runbook and tell the CTO so this guide gets updated.

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
# sudo ufw allow from 2001:db8:abcd::/48 to any port 22 proto tcp comment 'ssh board-admin v6'

# Public services
sudo ufw allow 80/tcp   comment 'http (ACME + redirect)'
sudo ufw allow 443/tcp  comment 'https/wss (caddy)'
sudo ufw allow 4000/tcp comment 'telnet (loom)'

sudo ufw logging low
sudo ufw --force enable
sudo ufw status verbose
```
Check SSH from a new terminal **before** you close the old one.
If admin IPs change often, use a VPN/Tailscale range as `ADMIN_SRC_IPS` rather than opening 22 to the world.

### 4.3 Docker bypasses ufw: fix it with `DOCKER-USER`
**The problem:** ports published by Docker (`ports:` in Compose) are DNAT-ed in the `nat` table and forwarded through the `FORWARD` chain. They never reach ufw's `INPUT` rules. So **any** published port is reachable from the internet, whatever `ufw status` says. Compose will publish only 80, 443 and 4000 (D-P1.14), but one wrong `ports:` line in a future PR (say `5432:5432`) would expose Postgres.

**The fix:** use Docker's `DOCKER-USER` chain, which Docker never flushes, to drop forwarded traffic from the public interface unless it's going to 80, 443 or 4000. Load it from ufw's `after.rules`, so it survives reboots and `ufw reload`:
```bash
EXT_IF=$(ip -o -4 route show to default | awk '{print $5; exit}')
for f in /etc/ufw/after.rules /etc/ufw/after6.rules; do
  sudo cp -n "$f" "$f.orig"
  sudo sed -i '/^# BEGIN LOOM-STAGING DOCKER-USER/,/^# END LOOM-STAGING DOCKER-USER/d' "$f"
  sudo tee -a "$f" >/dev/null <<EOF
# BEGIN LOOM-STAGING DOCKER-USER
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
# END LOOM-STAGING DOCKER-USER
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
nc -vz  -w 5 PUBLIC_IPV4 4000     # must SUCCEED (allowed)
nc -vz  -w 5 PUBLIC_IPV4 8081     # must FAIL/time out (the DOCKER-USER drop works)
```
Clean up on the host: `sudo docker rm -f fwtest && sudo docker image rm nginx:alpine`.

> **Run both `nc` tests from your workstation, not from the host.** A connection from the host to its own public IP goes through `OUTPUT`/loopback and `docker-proxy`. It never crosses `FORWARD` from `${EXT_IF}`, so it succeeds even when the provider firewall or `DOCKER-USER` blocks outside traffic. It proves only that the container is listening.

**If 4000 times out from the workstation**, find out where the SYN dies. On the host:
```bash
EXT_IF=$(ip -o -4 route show to default | awk '{print $5; exit}')
sudo iptables -Z DOCKER-USER                      # zero the counters
sudo timeout 20 tcpdump -ni "$EXT_IF" 'tcp port 4000 and tcp[tcpflags] & tcp-syn != 0'
# ...while that runs, repeat `nc -vz -w 5 PUBLIC_IPV4 4000` from the workstation...
sudo iptables -L DOCKER-USER -v -n --line-numbers
```
- **tcpdump shows no SYN from your workstation's IP:** the packet is being dropped *before* it reaches the VM. This is the provider firewall (§1.1), not ufw or Docker. Open TCP 4000 there. On IONOS, go to Cloud Panel → Network → Firewall Policies, add an inbound TCP 4000 rule to the policy assigned to the server, and wait for it to apply. IONOS's default policy opens only a few well-known ports (22/80/443 and a few others), not 4000.
- **SYN is seen and the `DROP` rule's counter goes up:** the `DOCKER-USER` allow rules aren't matching. Check that `sudo iptables -S DOCKER-USER` shows the real interface name, not an empty `! -i  -j RETURN`. Check that the `--ctorigdstport 4000` rule comes before `-j DROP`. Also check that `sudo iptables -S FORWARD` jumps to `DOCKER-USER` first.
- **SYN is seen and nothing is dropped, but there's still no reply:** check `sudo docker ps` for `0.0.0.0:4000->…`. Also run `sudo iptables -t nat -S DOCKER | grep 4000`.

### 4.4 Outbound
Leave outbound open (`ufw default allow outgoing`). GitHub, GHCR and ACME are served from rotating CDN IPs, so pinning egress by IP is fragile and not worth the risk for staging. If your provider **does** filter egress, allow these:

| Destination | Port | Used by |
|---|---|---|
| `github.com`, `codeload.github.com` | 443 | `git fetch` of `loom-gitops`; `mudlib-sync` clone of `LoomMud/warp` |
| `api.github.com` | 443 | reconciler posts the `staging/reconcile` commit status |
| `ghcr.io`, `pkg-containers.githubusercontent.com` | 443 | pull `ghcr.io/loommud/loom` (and blobs) |
| `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | 443 | pull `caddy`, `postgres`, `alpine/git` support images |
| `fulcio.sigstore.dev`, `rekor.sigstore.dev`, `tuf-repo-cdn.sigstore.dev` | 443 | `cosign verify` (keyless, Sigstore) |
| `acme-v02.api.letsencrypt.org` (and `acme.zerossl.com`, Caddy's fallback CA) | 443 | TLS certificates |
| your bucket endpoint (for example `s3.<region>.amazonaws.com`) | 443 | backups |
| `archive.ubuntu.com`, `security.ubuntu.com`, `download.docker.com` | 80/443 | OS and Docker updates |
| NTP/NTS servers (`ntp.ubuntu.com`, …) | UDP 123, TCP 4460 | time sync (chrony/NTS) |
| DNS resolvers | 53 | name resolution |

Quick outbound check from the host:
```bash
for u in https://github.com https://api.github.com https://ghcr.io/v2/ https://acme-v02.api.letsencrypt.org/directory https://rekor.sigstore.dev https://registry-1.docker.io/v2/; do
  printf '%-55s ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 "$u"
done
# Any HTTP code (200/301/401/404) means it's reachable; 000 means blocked.
```

---

## 5. DNS

1. At your DNS provider, create:
   - `staging.<domain>.  300  IN  A     PUBLIC_IPV4`
   - `staging.<domain>.  300  IN  AAAA  PUBLIC_IPV6` **only if** the host has working public IPv6 **and** ports 80/443/4000 are open on IPv6 (ufw rules in §4.2 cover v6 by default; check the provider firewall too). Let's Encrypt prefers IPv6 when an AAAA record exists, so a broken AAAA record makes certificate issuance fail. If in doubt, publish only the A record.
2. If `<domain>` has **CAA** records, they must allow the CA Caddy uses:
   ```bash
   dig +short CAA <domain>
   # If there's output, add:  <domain>. CAA 0 issue "letsencrypt.org"   (and optionally: 0 issue "sectigo.com" for ZeroSSL)
   ```
3. Find the host's real public addresses (on the host):
   ```bash
   curl -4 -s https://api.ipify.org; echo
   curl -6 -s --max-time 5 https://api6.ipify.org; echo    # empty or an error = no public IPv6
   ```
4. Verify from your workstation. Both must match step 3:
   ```bash
   dig +short A    staging.<domain> @1.1.1.1
   dig +short A    staging.<domain> @8.8.8.8
   dig +short AAAA staging.<domain> @1.1.1.1       # empty unless you published AAAA
   ```
   Wait for these to return the right IP **before** running the bootstrap (§9). Caddy requests the certificate on first start.

---

## 6. Backup bucket

What's required (D-P1.12): an S3-compatible bucket, private, with an access key that can **put, list and get in this bucket only** (no delete, no bucket admin), plus a lifecycle rule that expires objects after about 90 days.

### 6.1 Create the bucket
- Name: `loom-staging-backups` (or your own; note it as `BUCKET`).
- **Block all public access** on. Default server-side encryption on (SSE-S3 is fine; backups are also age-encrypted before upload).
- Versioning: optional. If you turn it on, also add a noncurrent-version expiry (below).

### 6.2 Bucket-scoped access key
**AWS S3:** create an IAM user (for example `loom-staging-backup`) with **no console access**, attach this inline policy, and create one access key for it:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListThisBucketOnly",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::loom-staging-backups"
    },
    {
      "Sid": "PutGetObjectsNoDelete",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::loom-staging-backups/*"
    }
  ]
}
```
Other providers, same intent:
- **Backblaze B2:** Application Key → "Allow access to bucket: `loom-staging-backups`", capabilities `listFiles`, `readFiles`, `writeFiles` (no `deleteFiles`). Use the S3 endpoint `https://s3.<region>.backblazeb2.com`.
- **MinIO:** `mc admin policy create` with the JSON above, then `mc admin user add` + `mc admin policy attach`.
- **Cloudflare R2:** R2 API tokens can't separate write from delete ("Object Read & Write" includes delete). If you use R2, scope the token to this one bucket and rely on the lifecycle rule plus the fact that backups are timestamped. Note this deviation on OBI-56 (without the token).

Put the access key ID and secret **only** in your password manager now, and in `secrets.env` in §9.

### 6.3 Lifecycle rule (~90 days)
**AWS** (from an admin workstation with an admin profile; **not** the backup key):
```bash
cat > lifecycle.json <<'EOF'
{
  "Rules": [
    {
      "ID": "expire-after-90-days",
      "Status": "Enabled",
      "Filter": {},
      "Expiration": { "Days": 90 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 30 },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket loom-staging-backups --lifecycle-configuration file://lifecycle.json
aws s3api get-bucket-lifecycle-configuration  --bucket loom-staging-backups
```
- **B2:** Bucket Settings → Lifecycle → custom: "hide after 90 days, delete 1 day after hiding".
- **R2 / MinIO / others:** an object-expiration rule with *Days = 90* for the whole bucket.

**TBD-by-R6: how retention is enforced.** R6 keeps 14 daily and 8 weekly backups. With a no-delete key, `rclone` can't prune old backups, so the options are:
- **(a) Recommended:** R6 writes to `daily/` and `weekly/` prefixes, and the board adds two more lifecycle rules (`daily/` → expire at 15 days, `weekly/` → expire at 60 days). The 90-day rule stays as the safety net. A compromised host can then never delete backups.
- **(b)** Grant `s3:DeleteObject` so that `rclone` prunes.

Until R6 confirms, apply only the 90-day rule. With small alpha dumps, 90 days of dailies costs very little.

### 6.4 Verify the key's scope (from a workstation, with the **backup** key)
```bash
export AWS_ACCESS_KEY_ID=…  AWS_SECRET_ACCESS_KEY=…  AWS_DEFAULT_REGION=<region>   # type them in, don't paste into chat
EP="--endpoint-url https://<s3-endpoint>"          # leave empty ("EP=") for AWS
echo ok | aws s3 cp - s3://loom-staging-backups/setup-check/ok.txt $EP   # put: must succeed
aws s3 ls s3://loom-staging-backups/setup-check/ $EP                     # list: must succeed
aws s3 cp s3://loom-staging-backups/setup-check/ok.txt - $EP             # get: prints "ok"
aws s3 rm s3://loom-staging-backups/setup-check/ok.txt $EP               # delete: must FAIL (AccessDenied)
aws s3 ls $EP                                                            # list other buckets: must FAIL
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```
(The leftover `setup-check/ok.txt` expires under the lifecycle rule.)

---

## 7. age keypair (offline)

The host **never** holds the private key. Backups are encrypted to the public key, and only the board can decrypt them (D-P1.12).

1. On an **offline or trusted admin workstation** (not the staging host), install `age` (`sudo apt install age` / `brew install age` / `winget install FiloSottile.age`), then:
   ```bash
   umask 077
   age-keygen -o loom-staging-backup.agekey
   # prints:  Public key: age1…   <- this is the only value you post
   age-keygen -y loom-staging-backup.agekey   # re-prints the public key at any time
   ```
2. Test a round trip:
   ```bash
   echo "restore-test" | age -r "$(age-keygen -y loom-staging-backup.agekey)" | age -d -i loom-staging-backup.agekey
   # expect: restore-test
   ```
3. **Store the private key** (the file with `AGE-SECRET-KEY-1…`):
   - in the board password manager (as a file attachment or secure note), **and**
   - one offline copy (an encrypted USB stick or a paper printout in a safe) held by a **second** board member.
   - Optional: wrap it with a passphrase, `age -p -o loom-staging-backup.agekey.age loom-staging-backup.agekey`, then store the `.age` file instead.
   - Then delete the plaintext from the workstation: `shred -u loom-staging-backup.agekey` (on macOS, `rm -P`).
4. **Never** copy the private key to the staging host, a Paperclip comment, a GitHub issue, chat or a screenshot.
5. Post the `age1…` public key on OBI-56 (§11). R6 commits it to `loom-gitops` staging config, where it's public by design.

**TBD-by-R6:** restore-drill procedure with the real key. The recommended approach is to run `staging/restore.sh` from an admin workstation, or on the host with the key streamed on stdin and never written to disk. Follow the R6 runbook when it lands.

---

## 8. GitHub token & GHCR

### 8.1 Fine-grained token for commit statuses
Pre-requisite (org owner, once): **LoomMud org → Settings → Personal access tokens → Settings**: allow fine-grained personal access tokens. If "require administrator approval" is on, approve the token after step 2.

1. As a board member: **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.**
   - **Token name:** `loom-staging-reconcile-status`
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
     -d '{"state":"success","context":"staging/setup-check","description":"board token check"}' | jq -r '.state, .context'
   # expect: success / staging/setup-check
   unset GH_STATUS_TOKEN
   ```
   On the token's page, check that the permissions list shows only *Commit statuses: Read and write* and *Metadata: Read-only*.

Statuses show the token owner's GitHub account as the creator. That's expected. (A GitHub App or machine user can replace the PAT later; it's out of scope for Phase 1.)

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
echo "$GHCR_TOKEN" | sudo -u loom-staging env HOME=/var/lib/loom-staging \
  docker login ghcr.io -u <github-username> --password-stdin
unset GHCR_TOKEN
sudo chmod 600 /var/lib/loom-staging/.docker/config.json
```
**TBD-by-R6:** R6 may instead read a `GHCR_TOKEN` variable from `secrets.env` and log in during reconcile. If `secrets.env.example` has such a variable, put the token there and skip the `docker login`.

---

## 9. Bootstrap & verification (OBI-56 item 8)

> Do this **when OBI-42 reaches its evidence step** and `staging/bootstrap.sh`, `staging/secrets.env.example` and the runbook exist on `loom-gitops` `main`. Until then, sections 1–8 are complete on their own.

### 9.1 Update the clone
```bash
sudo -u loom-staging git -C /opt/loom-gitops pull --ff-only
ls -l /opt/loom-gitops/staging/        # expect: bootstrap.sh, secrets.env.example, compose.yaml, images.env, runbook …
```

### 9.2 Fill in `secrets.env`
```bash
# Copy the template into place, keeping owner/mode
sudo install -o root -g loom-staging -m 0640 /opt/loom-gitops/staging/secrets.env.example /etc/loom-staging/secrets.env
# Generate the Postgres password (hex, so it needs no URL escaping in DATABASE_URL). Copy it into the password manager.
openssl rand -hex 24
# Edit in place. sudoedit keeps owner/mode and leaves no copy in shell history.
sudoedit /etc/loom-staging/secrets.env
sudo stat -c '%U:%G %a' /etc/loom-staging/secrets.env      # expect: root:loom-staging 640
```
Expected contents: `NAME=value`, one per line, no spaces around `=`.
**TBD-by-R6:** the **exact variable names** come from `secrets.env.example`. By design (D-P1.13) they cover:
- the Postgres password (from `openssl` above);
- the S3 endpoint, region, bucket, access key ID and secret access key (§6);
- the GitHub commit-status token (§8.1);
- a GHCR token, only if §8.2 fell back and R6 reads it from this file.

The **age public key is not a secret** and doesn't go here. R6 keeps it in repo config.

Don't `cat` the file on a shared screen, and don't paste its contents anywhere.

### 9.3 Run the bootstrap
```bash
sudo /opt/loom-gitops/staging/bootstrap.sh
```
**TBD-by-R6:** exact invocation (whether it must run as root via `sudo`, and any flags) and what it prints. By design it installs the reconciler systemd service + timer (every 2 min, `User=loom-staging`), checks `/etc/loom-staging/secrets.env` and its modes, and runs the first reconcile: fast-forward, `cosign verify`, `docker compose pull && up -d`, wait for healthy, and post the `staging/reconcile` status. Follow the R6 runbook if it differs.

### 9.4 Verification checklist
Tick every row. Rows marked (TBD-by-R6) use unit or route names that R6 fixes.

**On the host**

| # | Check | Command | Expect |
|---|---|---|---|
| H1 | Docker version | `sudo docker info --format '{{.ServerVersion}}'` | ≥ 24 |
| H2 | Compose v2 | `docker compose version` | v2+ |
| H3 | Docker at boot | `systemctl is-enabled docker; systemctl is-active docker` | `enabled` / `active` |
| H4 | Firewall | `sudo ufw status verbose` | deny incoming; allow 80, 443, 4000; 22 only from admin IPs |
| H5 | Docker bypass closed | `sudo iptables -S DOCKER-USER` | the §4.3 rules, ending in `-j DROP` |
| H6 | Listening ports | `sudo ss -tlnp` | public: 22, 80, 443, 4000 only (5432/8080/9090/3000 absent or bound to container networks) |
| H7 | Secrets file | `sudo stat -c '%U:%G %a' /etc/loom-staging /etc/loom-staging/secrets.env` | `root:loom-staging 750` / `root:loom-staging 640` |
| H8 | Containers healthy | `sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'` | `loom`, `caddy`, `postgres` `Up … (healthy)`; `mudlib-sync` exited 0 |
| H9 | Reconciler timer (TBD-by-R6: unit name) | `systemctl list-timers --all \| grep -i loom` | next run within 2 min |
| H10 | Reconciler log (TBD-by-R6) | `journalctl -u <reconcile-unit> -n 50 --no-pager` | cosign verified, compose up, status posted |
| H11 | Time sync | `timedatectl status` | synchronized: yes |
| H12 | Unattended upgrades | `systemctl is-active unattended-upgrades` | `active` |

**From an admin workstation (outside)**

| # | Check | Command | Expect |
|---|---|---|---|
| X1 | DNS | `dig +short A staging.<domain> @1.1.1.1` | `PUBLIC_IPV4` |
| X2 | Open ports | `for p in 80 443 4000; do nc -vz -w 5 staging.<domain> $p; done` | all succeed |
| X3 | Closed ports | `for p in 5432 8080 9090 3000 2375; do nc -vz -w 5 staging.<domain> $p; done` | all fail/time out |
| X4 | SSH restricted | `nc -vz -w 5 staging.<domain> 22` from a **non-admin** network (for example a phone hotspot) | fails/times out |
| X5 | HTTP→HTTPS | `curl -sSI http://staging.<domain>/ \| head -3` | `308`/`301` to `https://…` |
| X6 | TLS cert issued | `echo \| openssl s_client -connect staging.<domain>:443 -servername staging.<domain> 2>/dev/null \| openssl x509 -noout -issuer -subject -dates` | issuer Let's Encrypt (or ZeroSSL), subject `staging.<domain>`, valid dates |
| X7 | HTTPS works (strict) | `curl -sS -o /dev/null -w '%{http_code}\n' https://staging.<domain>/` | `200` (no `-k` needed) |
| X8 | Metrics not public | `curl -s -o /dev/null -w '%{http_code}\n' https://staging.<domain>/metrics` | `403` or `404`, **not** `200` |
| X9 | Telnet | `telnet staging.<domain> 4000` | Loom banner / login prompt (quit with `Ctrl-]` then `quit`) |
| X10 | Web client | open `https://staging.<domain>/` in a browser | web client loads and connects (WSS) |
| X11 | Reconcile status | `gh api repos/LoomMud/loom-gitops/commits/main/statuses --jq '[.[] \| select(.context=="staging/reconcile")][0] \| .state + " " + .description'` | `success …` |
| X12 | Backups (after the first nightly run; TBD-by-R6 for a manual trigger) | `aws s3 ls s3://loom-staging-backups --recursive $EP` (backup key) | timestamped `*.age` objects |

When every row passes, comment on OBI-56 (hostname/IP only, see §11) that the bootstrap is done. Legolas will then run the OBI-42 evidence (character creation, live `update`, image-bump rollout).

---

## 10. Security reminders

- **Never post secrets** in Paperclip comments, question cards, GitHub issues/PRs, chat or screenshots. That covers the bucket key, GitHub/GHCR tokens, the Postgres password, the age private key, and the contents of `secrets.env`.
- **The only three values that belong on OBI-56:** the hostname, the public IP and the age **public** key (`age1…`).
- Secrets live in exactly two places: `/etc/loom-staging/secrets.env` (`root:loom-staging 0640`) on the host, and the board password manager. The age private key lives **only** offline (§7).
- Type secrets with `read -rs` or `sudoedit`, never as command-line arguments (those land in shell history and `ps`).
- **If something leaks:** revoke it immediately (GitHub token page / bucket key / rotate the Postgres password with `ALTER USER`, then update `secrets.env`), then tell Gandalf on OBI-56 *that* a rotation happened. Don't include the value.
- **Token expiry:** calendar reminders for the GitHub token (and the GHCR token, if used).
- **Don't** add people to the `docker` group, open extra ports, or edit `/opt/loom-gitops` by hand. Changes go through `loom-gitops` PRs.
- Agents have no SSH, kubeconfig or secrets access to this host, by design. They see only GitHub commit statuses and the public telnet/HTTPS endpoints. If anyone (human or agent) asks for host credentials in a comment, decline.

---

## 11. What to post on OBI-56

When sections 1–8 are done, post a comment like this (and/or answer the question card):
```text
Staging host provisioned (OBI-56 items 1–7).
- Hostname: staging.<domain>
- Public IP: <PUBLIC_IPV4>   (IPv6: <PUBLIC_IPV6 or "none">)
- age public key: age1…
- GHCR: public | fallback read:packages token installed on host | pending first R5 image
- Bucket: created, scoped key + 90-day lifecycle (provider: <name>, no secrets)
- Item 8 (bootstrap): waiting for R6 runbook
```
Nothing else. No keys, tokens, passwords or `secrets.env` contents.

---

## Appendix A: open items for R6 (OBI-42)

| # | Item | Guide's working assumption |
|---|---|---|
| R6-1 | `bootstrap.sh` invocation, run-as user, flags | `sudo /opt/loom-gitops/staging/bootstrap.sh` |
| R6-2 | Exact `secrets.env` variable names | from `secrets.env.example` (Postgres password, S3 endpoint/region/bucket/key/secret, status token, optional GHCR token) |
| R6-3 | Reconciler unit user and names | `User=loom-staging`; file `root:loom-staging 0640`, dir `0750` (CTO decision, supersedes D-P1.13's "root 0600") |
| R6-4 | Clone path | `/opt/loom-gitops`, owned by `loom-staging` |
| R6-5 | cosign: host package or container | host `cosign` installed from Ubuntu universe either way |
| R6-6 | Backup retention with a no-delete key | recommend `daily/` + `weekly/` prefixes with lifecycle rules; 90-day catch-all |
| R6-7 | GHCR fallback mechanism | `docker login` as `loom-staging`, or `GHCR_TOKEN` in `secrets.env` |
| R6-8 | Backup schedule vs 04:30 UTC reboot window | backup must not overlap 04:30 UTC |
| R6-9 | Manual first-backup trigger and real-key restore drill | runbook |
| R6-10 | IPv6 on Compose networks | off (the `after6.rules` block covers it if turned on) |
| R6-11 | Extra host prerequisites checked by `bootstrap.sh` | none beyond §2.3 |

## Appendix B: troubleshooting

- **Locked out of SSH:** use the provider's web/serial console, then `sudo ufw allow from <your-ip> to any port 22 proto tcp`, or `sudo ufw disable` temporarily.
- **Certificate not issued:** check that DNS resolves (X1), that 80 and 443 are open (X2), that the AAAA record is correct or absent (§5), and CAA records (§5). Then `sudo docker logs caddy 2>&1 | grep -i acme`. Let's Encrypt rate-limits repeated failures, so fix the cause before restarting in a loop.
- **`docker compose pull` denied on `ghcr.io/loommud/loom`:** the package isn't public yet (§8.2), or the fallback login is missing or expired.
- **`staging/reconcile` status missing or failed with 401/403:** the status token has expired or lacks *Commit statuses: write* on `loom-gitops` (§8.1).
- **Reconcile blocked by "local changes":** someone edited `/opt/loom-gitops`. Run `sudo -u loom-staging git -C /opt/loom-gitops status`, then restore with `sudo -u loom-staging git -C /opt/loom-gitops checkout -- . && sudo -u loom-staging git -C /opt/loom-gitops clean -fd` (this discards local changes; they belong in a PR).
