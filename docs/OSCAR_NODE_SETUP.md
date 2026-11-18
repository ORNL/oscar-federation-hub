# Connecting OSCAR 3.11.0+ Nodes to `oscar-federation-hub`

This guide walks through connecting one or more **OSCAR `3.11.0+`** servers (Ubuntu Server 24.04 LTS or Windows 11 + WSL 2) to a self-hosted **OSCAR Federation Hub** so you can:

1. Reach firewalled or NATed OSCAR sites over outbound-only TLS (`https://<site>.hub.example.org`) without inbound port-forwarding.
2. Add, suspend, or change roles for operators across every federated OSCAR node from one place (`oscar-admins` -> `Administrator`, `oscar-operators` -> `Operator`, `oscar-viewers` -> `Viewer`).
3. Preserve **local offline Passkeys and passwords** on each OSCAR server so on-site staff can always sign in over the local LAN even if the wide-area network is disconnected.

---

## 1. Hybrid Identity Model (Central SSO + Local Offline Access)

OSCAR `3.11.0+` stores an explicit `authSource` per user record (`local`, `oidc`, or `tunnel`):

- **Central Federated Users (`oidc` / `tunnel`):** Provisioned automatically on first sign-in and synchronized on every login from your Hub's group claims (`oscar-admins`, `oscar-operators`, `oscar-viewers`). Removing a user in Authentik or Octelium immediately blocks central access across all sites.
- **Local Site Accounts (`local`):** Created inside OSCAR's **Users & Roles** page (passwords, YubiKeys, Windows Hello / Touch ID Passkeys, or printable Bulk QR Enrollment invites). Central OIDC or tunnel headers **never overwrite** the role of a `local` account, guaranteeing uninterrupted LAN break-glass access during internet outages.

---

## 2. Step-by-Step Setup on Each OSCAR Node

### Step 2.1 — Attach the Outbound Tunnel Connector

On the Hub host, register the OSCAR site:

```bash
./oscar-hub.sh add-site north-gate \
  --display-name "North Gate Portal" \
  --with-trusted-headers
```

Copy `state/tokens/north-gate.token` to the OSCAR server and run OSCAR's packaged remote-access script (delete the temporary token copy afterward — OSCAR stores it under `secrets/octelium-token.txt` with `0600` permissions and includes it in encrypted `oscar.sh backup` archives):

- **Linux (`oscar-remote-access.sh`):**
  ```bash
  sudo bash /srv/oscar/oscar-remote-access.sh configure \
    --domain hub.example.org \
    --service north-gate \
    --token-file /root/north-gate.token
  sudo shred -u /root/north-gate.token
  ```
- **Windows 11 + WSL 2 (`oscar-remote-access.ps1`, Administrator PowerShell):**
  ```powershell
  .\oscar-remote-access.ps1 configure `
    -Domain hub.example.org `
    -Service north-gate `
    -TokenFile C:\Users\Admin\north-gate.token
  Remove-Item -Force C:\Users\Admin\north-gate.token
  ```

Verify the sidecar container is healthy (`oscar-tunnel-1` runs alongside `oscar-gateway-1`, `oscar-oscar-1`, and `oscar-postgres-1`):

```bash
sudo bash /srv/oscar/oscar-remote-access.sh status
```

---

### Step 2.2 — Configure Central SSO in OSCAR (`Users & Roles -> Sign-In & SSO Policy`)

Sign into the OSCAR Viewer as an `Administrator`, open **Users** (`/users`), and select the **Sign-In & SSO Policy** tab.

#### Option 1: Authentik OIDC Single Sign-On (`--with-authentik`, Recommended)

Use the values printed by `./oscar-hub.sh init --domain hub.example.org --with-authentik`:

| OSCAR Field | Value |
| :--- | :--- |
| **Keep Password Sign-In Enabled** | `ON` (or `OFF` if local accounts use Passkeys only) |
| **Enable OIDC Single Sign-On** | `ON` |
| **SSO Button Label** | `Organization SSO` |
| **OIDC Issuer URL** | `https://auth.hub.example.org/application/o/oscar-federation-sso/` |
| **OIDC Client ID** | `oscar-federation-hub` |
| **OIDC Client Secret** | Contents of `state/secrets/oidc-client-secret.txt` on the Hub |
| **OIDC Scopes** | `openid profile email groups` |
| **Redirect URI Override** | *(Leave blank to auto-derive `<origin>/login/oidc/callback`, or set `https://north-gate.hub.example.org/login/oidc/callback`)* |
| **OIDC Custom CA Certificate Path** *(Optional)* | Leave blank for public TLS certificates (Let's Encrypt). For private/lab PKI, mount your root CA PEM into the OSCAR container (e.g. `/etc/oscar/certs/internal-ca.pem`) and enter that path here. |
| **Admin Group Value** | `oscar-admins` |
| **Operator Group Value** | `oscar-operators` |
| **Default OIDC Role** | `Viewer` |
| **External SSO User Console URL** | `https://auth.hub.example.org/if/admin/` |

Click **Save Sign-In Policy**. An **Open Federated User Console** button now appears at the top of OSCAR's **Users & Roles** page so administrators can jump straight to Authentik to add, disable, or re-role federated users in one click.

#### Option 2: Zero-Click Verified Tunnel Header SSO (`--with-trusted-headers`)

When `--with-trusted-headers` is passed to `./oscar-hub.sh add-site`, the Hub's Octelium envoy injects a cryptographic shared secret plus the authenticated operator's username and groups on every proxied HTTPS request. Operators who already signed into the Hub land directly inside OSCAR without a second login prompt:

| OSCAR Field | Value |
| :--- | :--- |
| **Enable Verified Tunnel Header SSO** | `ON` |
| **Verified Tunnel User Header** | `X-Octelium-User` |
| **Verified Tunnel Groups Header** | `X-Octelium-Groups` |
| **Tunnel Shared Secret** | Contents of `state/secrets/oscar-tunnel-shared-secret.txt` on the Hub |
| **Admin Group Value** | `oscar-admins` |
| **Operator Group Value** | `oscar-operators` |
| **Default Tunnel Role** | `Viewer` |
| **External SSO User Console URL** | `https://auth.hub.example.org/if/admin/` *(if using Authentik)* or `https://hub.example.org` |

> **Security Note:** OSCAR strips and ignores `X-Octelium-User` and `X-Octelium-Groups` unless `X-Oscar-Tunnel-Secret` matches the configured shared secret in constant time, preventing header spoofing from local LAN clients.

---

## 3. Node-to-Node Data Federation (`oscar_fed_*` Service Tokens)

Human SSO handles **operator browser access**, while **Node Federation** (aggregating live alarms, video, and national summaries onto a Central OSCAR server) uses dedicated machine credentials so revoking an employee never breaks site-to-central telemetry:

1. On each remote site OSCAR Viewer, open **Users -> Federation Tokens** and click **Mint Service Token**.
2. Click **Add Remote Server on Servers Page** (or copy the `oscar_fed_...` token to your Central OSCAR server's **Servers -> Add Node -> Federation Service Token** mode).
3. Enter the site's Hub hostname (`north-gate.hub.example.org`, TLS port `443`, Base Path `/sensorhub`) and save.
