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

On the Hub host, register the OSCAR site (which provisions both `https://north-gate.hub.example.org` for live operations and `https://north-gate-sandbox.hub.example.org` for OSCAR `3.11.5+`'s isolated Practice Sandbox on the same outbound connector token):

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

## 3. Node-to-Node Data Federation, Multi-Node Vehicle Search & Consolidated Reporting (`oscar_fed_*` Service Tokens)

Human SSO handles **operator browser access**, while **Node Federation** (aggregating live alarms, video, multi-node vehicle crossings, and consolidated incident reports onto a primary OSCAR server) uses dedicated machine credentials so revoking an employee never breaks site-to-central telemetry. Every site registered via `./oscar-hub.sh add-site` automatically enables authenticated cross-service CORS (`allowClusterServices: true` and `allowCredentials: true`) across `*.<hub-domain>` while preserving `Authorization: Bearer oscar_fed_...` and WebSocket MQTT (`wss://<site>.<hub-domain>/sensorhub/mqtt`):

1. **Mint a Scoped Service Token on the Remote Node:** Sign into the remote OSCAR Viewer (for example, `https://west-gate.hub.example.org`), open **Users & Access (`/users`) -> Federation Tokens**, enter a descriptive label, choose `Viewer` (read-only monitoring/search/reporting) or `Operator` (cross-node linked adjudication), and click **Create Federation Token**. Copy the generated `oscar_fed_<shortId>_<secret>` token.
2. **Add the Remote Server on the Primary OSCAR Node:** On your primary/HQ OSCAR Viewer (for example, `https://central-hq.hub.example.org`), open **Servers (`/servers?auth=bearer`)** (or click **Add Server -> Use Federation Token (`oscar_fed_...`)**), enter a clear site **Name** (e.g., `West Gate Portal`), enter **Address** `west-gate.hub.example.org` with **Port** `443` and **Use a secure connection** (`HTTPS`) checked, paste the `oscar_fed_...` token, and click **Add Node**.
3. **Run a Multi-Node Vehicle Search (`Events -> Compare Passes`):** Open **Events (`/event-log`)**, enter a shipping container or license plate in the **Vehicle ID** search bar (ISO 6346 container numbers and plates normalize punctuation automatically), and click **Compare Passes**. OSCAR queries both the local node and every federated remote node in parallel, displaying side-by-side transits with each server's name, saved OCR/keyframe crops, and overlaid gamma/neutron profiles.
4. **Generate a Multi-Node Consolidated Vehicle Incident Report (`Report Generator` or Dialog Export):** Either click **Export PDF / CSV / JSON / XLSX** directly inside **Compare Vehicle Crossings**, or open **Report Generator (`/report`)**, select **Vehicle Incident (`VEHICLE_INCIDENT`)**, enter the **Vehicle ID**, keep **Include Federated Servers** checked, and click **Generate Report** to produce a single report combining crossings from all federated OSCAR nodes.

---

## 4. Adding Federated Users & Sending 1-Tap SSO Passkey Setup Links in Authentik

The bundled Blueprint (`blueprints/oscar-federation.yaml.tmpl`) pre-wires two Passkey flows automatically:
- **`oscar-passkey-onboarding`** (`Set Up Your OSCAR SSO Passkey`) — bound as the Brand's **Recovery Flow**, so clicking **Create recovery link** on any user generates a single-use URL that immediately enrolls their discoverable FIDO2 Passkey (Face ID, Touch ID, Windows Hello, or YubiKey) and signs them in without needing a password.
- **`oscar-passkey-login`** (`Sign In with OSCAR SSO Passkey`) — bound as the Identification Stage's **Passwordless Flow**, adding a 1-click **Use a security key** Passkey button directly on the Authentik SSO sign-in card.

### 4-Step Admin Onboarding Workflow

1. **Open Authentik Admin (`https://auth.hub.example.org/if/admin/`):** Sign in with an administrator account (member of `authentik Admins`) and select **Directory -> Users -> Create**.
2. **Create the User Record:** Enter a lowercase **Username** (e.g. `alexe`), **Name** (`Alex E`), and **Email** (`alexe@example.org` — required so the 30-second `oscar-hub-sync.timer` reconciles the user into Octelium), leaving **User type** set to `Internal`, then click **Create**.
3. **Assign the OSCAR Role Group:** Click the new username in the table, open the **Groups** tab, click **Add to existing group**, and add one of:
   - `oscar-admins` (`Administrator`)
   - `oscar-operators` (`Operator`)
   - `oscar-viewers` (`Viewer`)
4. **Generate & Send the Single-Use SSO Passkey Setup Link:** Return to the **Overview** tab on that user's page, click **Create recovery link** under **Recovery**, copy the single-use `https://auth.hub.example.org/if/flow/oscar-passkey-onboarding/?token=...` link, and send it to the user. When the user opens the link, they register their Passkey in one tap and can immediately sign in to any federated OSCAR site (`https://<site>.hub.example.org`) via **Organization SSO -> Use a security key**.

---

## 5. Offboarding & Permanently Deleting Federated Users (3-Layer Revocation)

When an operator, viewer, or contractor leaves the organization, complete access revocation removes the identity at all three layers so zero active sessions, Passkeys, tunnel routes, or cached OSCAR user entries remain:

1. **Delete the User in Authentik (`https://auth.hub.example.org/if/admin/#/identity/users`):**
   - Open **Directory -> Users**, select the user row(s) to revoke, click **Delete** in the toolbar, and confirm **Delete** in the confirmation dialog.
   - Deleting the Authentik user immediately destroys all enrolled WebAuthn Passkeys, recovery links, and OIDC refresh grants for that user.
2. **Verify Automatic Octelium Zero-Trust Hub Purge (`oscar-hub-sync.timer` / `sync-users`):**
   - Every user synced from Authentik carries the label `managed-by: authentik-sync`. Within **30 seconds**, `oscar-hub-sync.timer` automatically invokes `octeliumctl delete user <username>` for any user deleted, deactivated, or removed from `oscar-*` groups in Authentik.
   - To force immediate zero-second reconciliation on the Hub host and verify removal:
     ```bash
     sudo -H /opt/oscar-federation-hub/oscar-hub.sh sync-users
     sudo -H OCTELIUM_DOMAIN=hub.example.org octeliumctl get user
     ```
3. **Remove Any Cached User Rows in OSCAR (`Users & Access -> Users & Roles`):**
   - Sign into each federated OSCAR node (`/users`), open the **Users & Roles** tab, click **Sign Out Devices** (if any browser session was still active) followed by **Delete** on the offboarded username, and confirm **Delete**.
   - Attempting to sign in via **Organization SSO** as the deleted user now fails immediately at the Hub authentication boundary.

---

## 6. 24/7 Unattended Wallboards & Automatic Tunnel Session Self-Heal

Control-room wallboards running continuously over Verified Tunnel Header SSO (`--with-trusted-headers`) stay authenticated 24/7 without manual browser refreshes:

- When an upstream tunnel proxy token or cookie rotates on a background XHR/ConSys `fetch`, the browser receives an opaque CORS redirect or `401`/`403` from the Zero-Trust edge before hitting OSCAR.
- OSCAR's `TunnelSessionSelfHeal` client guard detects cross-origin tunnel re-auth challenges automatically, silently refreshes the tunnel session via a hidden same-site handshake (with exponential cooldown so transient WAN blips never cause reload loops), and resumes live `5 Hz` MQTT radiation plots and Dashboard alarm queues uninterrupted.
