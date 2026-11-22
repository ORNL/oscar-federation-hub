# OSCAR Federation Hub

Turnkey, self-hosted **Zero-Trust Remote Access** and **Centralized SSO User Management** companion stack for federated [ORNL/oscar](https://github.com/ORNL/oscar) (`3.11.0+`) deployments.

`oscar-federation-hub` combines two open-source components behind a single setup script (`oscar-hub.sh`) so multi-site OSCAR administrators can expose outbound-only sites securely and add or revoke operator access across every federated portal from one place:

1. **[Octelium](https://github.com/octelium/octelium)** — Self-hosted Zero-Trust network access (ZTNA) hub. Each remote OSCAR server dials **outbound** over TLS `443` using OSCAR's built-in `oscar-remote-access.sh` / `oscar-remote-access.ps1` sidecar (`compose.octelium.yaml`) — zero inbound firewall port-forwards required at field sites.
2. **[Authentik](https://goauthentik.io/) *(Optional, `--with-authentik`)*** — Self-hosted OpenID Connect (OIDC) Identity Provider with a browser admin console (`https://auth.hub.example.org/if/admin/`) pre-provisioned via Blueprint with OSCAR's exact RBAC groups (`oscar-admins`, `oscar-operators`, `oscar-viewers`), MFA/Passkey enrollment flows, and wildcard callback matching for `https://<site>.<hub-domain>/login/oidc/callback`.

---

## Choose Your Operating Mode

| Capability | Mode A: Browser Admin GUI (`--with-authentik`, Recommended) | Mode B: Lightweight CLI (Default, `octeliumctl` only) |
| :--- | :--- | :--- |
| **Outbound Zero-Trust Tunnel (`443`)** | Yes (Octelium) | Yes (Octelium) |
| **How Admins Add / Disable Users** | Point-and-click web console (`https://auth.<domain>/if/admin/`) with automatic 30s Octelium user/group sync | `./oscar-hub.sh add-user` / `remove-user` CLI |
| **Role Assignment Across Federated Sites** | Drag user into `oscar-admins`, `oscar-operators`, or `oscar-viewers` | `--group oscar-admins \| oscar-operators \| oscar-viewers` |
| **1-Click Shortcut Inside OSCAR `/users`** | **Open Federated User Console** button opens Authentik directly | Optional |
| **Extra Hub RAM Footprint** | ~1.5 GB (Authentik + PostgreSQL + Redis in K3s or Docker; 8 GB total Hub RAM recommended) | Minimal (Octelium cluster only) |
| **Coexists with Local OSCAR Passkeys?** | **Yes** — local emergency accounts & hardware Passkeys continue working offline on LAN | **Yes** |

---

## Prerequisites on the Central Hub Host

1. A Linux server or VM reachable on TCP/UDP `443` with a wildcard DNS record pointing to it:
   - `hub.example.org` -> Hub public/VPN IP
   - `*.hub.example.org` -> Hub public/VPN IP (covers `auth.hub.example.org`, `north-gate.hub.example.org`, `central.hub.example.org`, etc.)
2. An initialized [Octelium](https://octelium.com/docs) cluster on the Hub host with `octeliumctl` authenticated as admin.
3. For `--with-authentik`: `oscar-hub.sh` automatically detects **K3s (`kubectl`)** on standard Octelium Hub hosts (`--runtime k8s`) and exposes `https://auth.<domain>` through Octelium's wildcard TLS edge, or falls back to Docker Engine `24+` with `docker compose` v2 (`--runtime docker`).

---

## 3-Step Quickstart

### Step 1 — Initialize the Hub

Clone this repository on your central Hub host and initialize either **Mode A (Browser Admin GUI)** or **Mode B (Lightweight CLI)**:

```bash
git clone https://github.com/ORNL/oscar-federation-hub.git
cd oscar-federation-hub

# Mode A (Recommended): Octelium + Authentik Browser User Console
./oscar-hub.sh init --domain hub.example.org --with-authentik --admin-email secops@example.org

# OR Mode B (Lightweight): Octelium CLI-only user management
./oscar-hub.sh init --domain hub.example.org
```

All generated credentials, OIDC secrets, and site connector tokens are written with `0600` permissions inside `state/` (which is excluded by `.gitignore`).

### Step 2 — Register Each Federated OSCAR Site

Mint a least-privilege workload connector token and publish both the operational site route (`https://north-gate.hub.example.org`) and its isolated ephemeral **Practice Sandbox** subdomain (`https://north-gate-sandbox.hub.example.org` for OSCAR `3.11.5+`, reusing the same connector token with hard browser origin isolation, automatic Let's Encrypt TLS, and shared Passkey `rpId`) in one command:

```bash
./oscar-hub.sh add-site north-gate \
  --display-name "North Gate Portal" \
  --with-trusted-headers
```

Copy `state/tokens/north-gate.token` securely to that OSCAR `3.11.0+` server and run OSCAR's built-in remote-access helper:

```bash
# On Linux OSCAR 3.11.0+
sudo bash oscar-remote-access.sh configure \
  --domain hub.example.org \
  --service north-gate \
  --token-file /root/north-gate.token
```

```powershell
# Or on Windows 11 WSL2 OSCAR 3.11.0+ (Administrator PowerShell)
.\oscar-remote-access.ps1 configure `
  -Domain hub.example.org `
  -Service north-gate `
  -TokenFile C:\Users\Admin\north-gate.token
```

### Step 3 — Connect OSCAR Sign-In & Manage Users Centrally

See **[docs/OSCAR_NODE_SETUP.md](docs/OSCAR_NODE_SETUP.md)** for the complete walkthrough of:
- Wiring **OIDC Single Sign-On** (`https://auth.hub.example.org/application/o/oscar-federation-sso/`) or **Zero-Click Trusted Tunnel Header SSO** (`X-Octelium-User` + `X-Octelium-Groups`) in OSCAR's **Users & Roles -> Sign-In & SSO Policy** tab.
- Adding the **External SSO User Console URL** (`https://auth.hub.example.org/if/admin/`) so administrators get a 1-click **Open Federated User Console** button inside OSCAR.
- Supplying a private/lab root CA PEM file (`OIDC Custom CA Certificate Path`) when running on an internal PKI without public Let's Encrypt certificates.
- Keeping local offline Passkey/password break-glass accounts active alongside federated SSO.

---

## Day-2 Administration Cheat Sheet

```bash
# Inspect Hub status, pinned versions, registered sites, and Authentik health
./oscar-hub.sh status

# Register another OSCAR server
./oscar-hub.sh add-site south-dock --display-name "South Dock RPMs" --with-trusted-headers

# Update an existing site's route/headers in place without rotating its connector token
./oscar-hub.sh add-site south-dock --display-name "South Dock RPMs" --connector-user oscar-node-south-dock --no-mint-token --with-trusted-headers

# Force an immediate Authentik -> Octelium user/group reconciliation (also runs automatically every 30s)
./oscar-hub.sh sync-users

# Decommission a site and revoke its workload token immediately
./oscar-hub.sh remove-site south-dock

# Mode B (CLI-only): add or revoke a human operator
./oscar-hub.sh add-user jsmith --email jsmith@example.org --group oscar-operators
./oscar-hub.sh remove-user jsmith

# Apply tested container version updates from versions.env
git pull && ./oscar-hub.sh upgrade
```

---

## Pinned Versions & Automated Updates

Container tags are pinned in [`versions.env`](versions.env) rather than floating `:latest` tags so field deployments remain reproducible. GitHub Dependabot and `.github/workflows/ci.yml` validate shell syntax (`shellcheck`), Compose rendering, and `tests/test-oscar-hub.sh` automatically on every update.

## License

Mozilla Public License 2.0 ([LICENSE](LICENSE)).
