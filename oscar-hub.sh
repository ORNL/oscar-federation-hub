#!/usr/bin/env bash
# ==============================================================================
# OSCAR Federation Hub CLI (Octelium Zero-Trust + Optional Authentik OIDC GUI)
# Turnkey self-hosted remote access & centralized SSO user management for
# federated OSCAR deployments.
# ==============================================================================
set -Eeuo pipefail

umask 077

script_path=${BASH_SOURCE[0]}
case $script_path in */*) script_parent=${script_path%/*} ;; *) script_parent=. ;; esac
repo_root=$(CDPATH='' cd -- "$script_parent" && pwd -P)

versions_file="$repo_root/versions.env"
state_dir="${OSCAR_HUB_STATE_DIR:-$repo_root/state}"
secrets_dir="$state_dir/secrets"
tokens_dir="$state_dir/tokens"
rendered_dir="$state_dir/rendered"
sites_dir="$state_dir/sites"
config_file="$state_dir/hub.env"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

valid_dns_name() {
    local value=$1
    [[ $value =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ && $value == *.* && $value != *..* ]]
}

valid_slug() {
    local value=$1
    [[ $value =~ ^[a-z0-9]([a-z0-9-]{0,46}[a-z0-9])?$ ]]
}

valid_username() {
    local value=$1
    [[ $value =~ ^[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?$ ]]
}

valid_email() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

valid_duration() {
    local value=$1
    [[ $value =~ ^[1-9][0-9]*(hours|days|months)$ ]]
}

random_hex() {
    local bytes=${1:-24}
    od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

read_kv() {
    local file=$1 key=$2
    [[ -f $file ]] || return 0
    awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'
}

load_versions() {
    [[ -f $versions_file ]] || fail "Missing versions file: $versions_file"
    OCTELIUM_VERSION=$(read_kv "$versions_file" OCTELIUM_VERSION)
    AUTHENTIK_VERSION=$(read_kv "$versions_file" AUTHENTIK_VERSION)
    POSTGRES_VERSION=$(read_kv "$versions_file" POSTGRES_VERSION)
    REDIS_VERSION=$(read_kv "$versions_file" REDIS_VERSION)
    export OCTELIUM_VERSION AUTHENTIK_VERSION POSTGRES_VERSION REDIS_VERSION
}

require_initialized() {
    [[ -f $config_file ]] || fail "Hub is not initialized yet. Run: ./oscar-hub.sh init --domain <hub.example.org> [--with-authentik]"
}

run_octeliumctl() {
    local dry_run=$1 hub_domain=$2
    shift 2
    if [[ $dry_run == true ]]; then
        printf '[dry-run] OCTELIUM_DOMAIN=%s octeliumctl %s\n' "$hub_domain" "$*"
        return 0
    fi
    command -v octeliumctl >/dev/null 2>&1 || fail "octeliumctl is not installed on PATH. Install octeliumctl ${OCTELIUM_VERSION} on this Hub host first."
    OCTELIUM_DOMAIN="$hub_domain" octeliumctl "$@"
}

detect_authentik_runtime() {
    local requested=$1 dry_run=$2
    case $requested in
        k8s|docker) printf '%s\n' "$requested"; return 0 ;;
        auto)
            if [[ $dry_run == true ]]; then
                printf 'docker\n'
                return 0
            fi
            if command -v kubectl >/dev/null 2>&1 && kubectl get ns octelium >/dev/null 2>&1; then
                printf 'k8s\n'
                return 0
            fi
            printf 'docker\n'
            ;;
        *) fail "Invalid --runtime '$requested' (use auto, k8s, or docker)." ;;
    esac
}

ensure_secret_file() {
    local path=$1 bytes=${2:-24}
    if [[ -f $path ]]; then
        cat -- "$path"
    else
        local val
        val=$(random_hex "$bytes")
        printf '%s\n' "$val" >"$path"
        chmod 0600 "$path"
        printf '%s' "$val"
    fi
}

install_sync_systemd_timer() {
    local hub_script="$repo_root/oscar-hub.sh"
    [[ $(id -u) -eq 0 ]] && command -v systemctl >/dev/null 2>&1 || return 0
    cat >/etc/systemd/system/oscar-hub-sync.service <<EOF
[Unit]
Description=OSCAR Federation Hub Authentik-to-Octelium User Sync
After=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
Environment=OSCAR_HUB_STATE_DIR=$state_dir
ExecStart=/usr/bin/env bash $hub_script sync-users
EOF
    cat >/etc/systemd/system/oscar-hub-sync.timer <<'EOF'
[Unit]
Description=Run OSCAR Federation Hub User Sync every 30 seconds

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now oscar-hub-sync.timer >/dev/null 2>&1 || true
}

maybe_refresh_certbot_san() {
    local domain=$1 required_fqdn=$2 dry_run=$3
    [[ $dry_run != true && $(id -u) -eq 0 ]] || return 0
    local live_dir="/etc/letsencrypt/live/$domain"
    [[ -f "$live_dir/fullchain.pem" && -f "$live_dir/privkey.pem" ]] || return 0
    command -v certbot >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || return 0

    local sans
    sans=$(openssl x509 -in "$live_dir/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true)
    if grep -Fq -- "DNS:*.$domain" <<<"$sans" || grep -Fq -- "DNS:$required_fqdn" <<<"$sans"; then
        return 0
    fi

    info "Expanding Let's Encrypt HTTP-01 certificate ($domain) to include $required_fqdn..."
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat >/etc/letsencrypt/renewal-hooks/deploy/octelium-cert-sync.sh <<EOF
#!/usr/bin/env bash
if command -v kubectl >/dev/null 2>&1 && kubectl -n octelium get secret cert-cluster >/dev/null 2>&1; then
    kubectl -n octelium create secret tls cert-cluster \\
        --cert="$live_dir/fullchain.pem" \\
        --key="$live_dir/privkey.pem" \\
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
EOF
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/octelium-cert-sync.sh

    local -a domain_args=()
    local d
    while IFS= read -r d; do
        [[ -n $d ]] && domain_args+=(-d "$d")
    done < <(
        printf '%s\n' "$sans" \
            | tr ',' '\n' \
            | sed -n 's/.*DNS:\([A-Za-z0-9.*-]*\).*/\1/p' \
            | awk -v req="$required_fqdn" 'BEGIN { seen[req]=1; print req } !seen[$0]++ { print $0 }'
    )

    certbot certonly --cert-name "$domain" --standalone --http-01-port 18080 \
        --pre-hook "iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j REDIRECT --to-ports 18080" \
        --post-hook "iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 18080 2>/dev/null || true" \
        --expand --non-interactive --agree-tos "${domain_args[@]}"
    /etc/letsencrypt/renewal-hooks/deploy/octelium-cert-sync.sh
}

usage() {
    cat <<'EOF'
Usage: ./oscar-hub.sh <command> [options]

Commands:
  init        Initialize the Hub configuration, secrets, and optional Authentik SSO stack
              Options:
                --domain <hub.example.org>      Base Hub domain (required)
                --with-authentik                Deploy Authentik browser SSO & pre-wired OSCAR groups
                --runtime <auto|k8s|docker>     Authentik runtime (default: auto — uses K3s on Octelium hosts)
                --admin-email <admin@org.tld>   Bootstrap email for Authentik akadmin (default: admin@<domain>)
                --bind-address <ip>             Authentik bind IP in docker mode (default: 127.0.0.1)
                --dry-run                       Render configs and secrets without invoking K3s/Docker/octeliumctl

  add-site    Register a federated OSCAR server and mint its scoped outbound connector token
              Options:
                <site-slug>                     DNS-safe site name (e.g. north-gate -> north-gate.<domain>)
                --display-name "<Label>"        Human-readable site title
                --connector-user <name>         Octelium WORKLOAD user name (default: oscar-node-<site-slug>)
                --no-mint-token                 Keep existing connector token when updating a live site in place
                --with-trusted-headers          Inject X-Oscar-Tunnel-Secret, X-Octelium-User & X-Octelium-Groups
                --expire-in <duration>          Connector token validity (default: 90days)
                --dry-run                       Render manifests without invoking octeliumctl

  remove-site Remove a federated OSCAR site service and revoke its workload connector
              Options:
                <site-slug>                     Site slug to remove
                --connector-user <name>         Octelium WORKLOAD user name (default: oscar-node-<site-slug>)
                --dry-run                       Preview removal commands

  sync-users  Reconcile Authentik users & OSCAR role groups (oscar-admins/operators/viewers) into Octelium
              Options:
                --dry-run                       Preview user sync without invoking octeliumctl

  add-user    Add a human operator directly via octeliumctl (for lightweight mode without Authentik)
              Options:
                <username>                      Lowercase username (e.g. jsmith)
                --email <user@org.tld>          User email address (required)
                --group <group>                 oscar-admins | oscar-operators | oscar-viewers (default: oscar-operators)
                --expire-in <duration>          Browser login token validity (default: 30days)
                --dry-run                       Render manifest without invoking octeliumctl

  remove-user Revoke a human user in octeliumctl-only mode
              Options:
                <username>                      Username to remove
                --dry-run                       Preview removal command

  status      Show Hub configuration, registered OSCAR sites, and Authentik health
  upgrade     Pull pinned container versions from versions.env and rolling-restart Authentik
EOF
}

cmd_init() {
    local domain="" with_authentik="false" runtime_req="auto" admin_email="" bind_address="127.0.0.1" dry_run="false"
    while (($# > 0)); do
        case $1 in
            --domain) domain=${2:-}; shift 2 ;;
            --with-authentik) with_authentik="true"; shift ;;
            --runtime) runtime_req=${2:-}; shift 2 ;;
            --admin-email) admin_email=${2:-}; shift 2 ;;
            --bind-address) bind_address=${2:-}; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) fail "Unknown option for init: $1" ;;
        esac
    done

    domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
    [[ -n $domain ]] || fail "--domain <hub.example.org> is required."
    valid_dns_name "$domain" || fail "Invalid DNS domain: $domain"
    [[ -n $admin_email ]] || admin_email="admin@$domain"
    valid_email "$admin_email" || fail "Invalid --admin-email: $admin_email"
    [[ $bind_address =~ ^[0-9A-Fa-f:.]+$ ]] || fail "Invalid --bind-address: $bind_address"

    load_versions
    local runtime
    runtime=$(detect_authentik_runtime "$runtime_req" "$dry_run")

    mkdir -p "$secrets_dir" "$tokens_dir" "$rendered_dir" "$sites_dir"
    chmod 0700 "$state_dir" "$secrets_dir" "$tokens_dir" "$rendered_dir" "$sites_dir"

    local oidc_client_id="oscar-federation-hub"
    local oidc_client_secret pg_pass ak_secret ak_bootstrap ak_sync_token tunnel_shared_secret
    oidc_client_secret=$(ensure_secret_file "$secrets_dir/oidc-client-secret.txt" 24)
    pg_pass=$(ensure_secret_file "$secrets_dir/authentik-postgres-password.txt" 24)
    ak_secret=$(ensure_secret_file "$secrets_dir/authentik-secret-key.txt" 32)
    ak_bootstrap=$(ensure_secret_file "$secrets_dir/authentik-bootstrap-password.txt" 16)
    ak_sync_token=$(ensure_secret_file "$secrets_dir/authentik-sync-token.txt" 24)
    tunnel_shared_secret=$(ensure_secret_file "$secrets_dir/oscar-tunnel-shared-secret.txt" 24)
    chmod 0600 "$secrets_dir"/*.txt

    cat >"$config_file" <<EOF
HUB_DOMAIN=$domain
WITH_AUTHENTIK=$with_authentik
AUTHENTIK_RUNTIME=$runtime
ADMIN_EMAIL=$admin_email
OIDC_CLIENT_ID=$oidc_client_id
AUTHENTIK_BIND_ADDRESS=$bind_address
EOF
    chmod 0600 "$config_file"

    local auth_service_block=""
    if [[ $with_authentik == true ]]; then
        local esc_domain esc_secret esc_sync esc_regex_domain
        esc_domain=$(escape_sed_replacement "$domain")
        esc_secret=$(escape_sed_replacement "$oidc_client_secret")
        esc_sync=$(escape_sed_replacement "$ak_sync_token")
        esc_regex_domain=$(escape_sed_replacement "$(printf '%s' "$domain" | sed -e 's/\./\\./g')")

        sed \
            -e "s/__HUB_DOMAIN__/$esc_domain/g" \
            -e "s/__HUB_DOMAIN_ESCAPED__/$esc_regex_domain/g" \
            -e "s/__OIDC_CLIENT_ID__/$oidc_client_id/g" \
            -e "s/__OIDC_CLIENT_SECRET__/$esc_secret/g" \
            -e "s/__AUTHENTIK_SYNC_TOKEN__/$esc_sync/g" \
            "$repo_root/blueprints/oscar-federation.yaml.tmpl" >"$rendered_dir/oscar-federation.yaml"
        chmod 0600 "$rendered_dir/oscar-federation.yaml"

        cat >"$state_dir/authentik.env" <<EOF
POSTGRES_VERSION=$POSTGRES_VERSION
REDIS_VERSION=$REDIS_VERSION
AUTHENTIK_VERSION=$AUTHENTIK_VERSION
AUTHENTIK_POSTGRES_USER=authentik
AUTHENTIK_POSTGRES_DB=authentik
AUTHENTIK_POSTGRES_PASSWORD=$pg_pass
AUTHENTIK_SECRET_KEY=$ak_secret
AUTHENTIK_BOOTSTRAP_PASSWORD=$ak_bootstrap
AUTHENTIK_BOOTSTRAP_EMAIL=$admin_email
AUTHENTIK_BOOTSTRAP_TOKEN=$ak_sync_token
AUTHENTIK_BIND_ADDRESS=$bind_address
AUTHENTIK_BLUEPRINT_FILE=$rendered_dir/oscar-federation.yaml
EOF
        chmod 0600 "$state_dir/authentik.env"

        sed \
            -e "s/__POSTGRES_VERSION__/$(escape_sed_replacement "$POSTGRES_VERSION")/g" \
            -e "s/__REDIS_VERSION__/$(escape_sed_replacement "$REDIS_VERSION")/g" \
            -e "s/__AUTHENTIK_VERSION__/$(escape_sed_replacement "$AUTHENTIK_VERSION")/g" \
            -e "s/__POSTGRES_PASSWORD__/$(escape_sed_replacement "$pg_pass")/g" \
            -e "s/__AUTHENTIK_SECRET_KEY__/$(escape_sed_replacement "$ak_secret")/g" \
            -e "s/__AUTHENTIK_BOOTSTRAP_PASSWORD__/$(escape_sed_replacement "$ak_bootstrap")/g" \
            -e "s/__ADMIN_EMAIL__/$(escape_sed_replacement "$admin_email")/g" \
            -e "s/__AUTHENTIK_SYNC_TOKEN__/$esc_sync/g" \
            "$repo_root/templates/k8s-authentik.yaml.tmpl" >"$rendered_dir/k8s-authentik.yaml"
        chmod 0600 "$rendered_dir/k8s-authentik.yaml"

        if [[ $runtime == k8s ]]; then
            auth_service_block=$(cat <<'EOF'
---
kind: Service
metadata:
  name: auth
  displayName: Organization SSO (Authentik)
spec:
  mode: WEB
  isPublic: true
  isAnonymous: true
  config:
    tls:
      insecureSkipVerify: true
    http:
      header:
        host:
          preserve: true
    upstream:
      url: https://authentik-server.oscar-authentik.svc:9443
EOF
)
            if [[ $dry_run == true ]]; then
                info "[dry-run] Would deploy Authentik $AUTHENTIK_VERSION into K3s namespace oscar-authentik."
            else
                info "Deploying Authentik $AUTHENTIK_VERSION into K3s namespace oscar-authentik..."
                kubectl create namespace oscar-authentik --dry-run=client -o yaml | kubectl apply -f -
                kubectl -n oscar-authentik create configmap oscar-federation-blueprint \
                    --from-file=oscar-federation.yaml="$rendered_dir/oscar-federation.yaml" \
                    --dry-run=client -o yaml | kubectl apply -f -
                kubectl apply -f "$rendered_dir/k8s-authentik.yaml"
                kubectl -n oscar-authentik rollout status deploy/authentik-postgres --timeout=180s
                kubectl -n oscar-authentik rollout status deploy/authentik-redis --timeout=180s
                kubectl -n oscar-authentik rollout status deploy/authentik-server --timeout=300s
                kubectl -n oscar-authentik rollout status deploy/authentik-worker --timeout=300s
            fi
        else
            if [[ $dry_run == true ]]; then
                info "[dry-run] Would start Authentik stack via docker compose --env-file $state_dir/authentik.env -f compose.authentik.yaml up -d"
            else
                info "Starting Authentik SSO stack (ghcr.io/goauthentik/server:$AUTHENTIK_VERSION)..."
                docker compose --project-name oscar-hub-sso \
                    --env-file "$state_dir/authentik.env" \
                    --file "$repo_root/compose.authentik.yaml" \
                    up --detach --wait
            fi
        fi
    fi

    awk -v block="$auth_service_block" '{
        if ($0 == "__AUTHENTIK_SERVICE_BLOCK__") {
            if (length(block) > 0) print block
        } else {
            print $0
        }
    }' "$repo_root/templates/octelium-base-resources.yaml.tmpl" >"$rendered_dir/octelium-base.yaml"
    chmod 0600 "$rendered_dir/octelium-base.yaml"

    cat >"$rendered_dir/octelium-secrets.yaml" <<EOF
kind: Secret
metadata:
  name: oscar-tunnel-shared-secret
spec: {}
data:
  value: "$tunnel_shared_secret"
EOF
    chmod 0600 "$rendered_dir/octelium-secrets.yaml"

    info "Applying base Octelium secrets, policies, and OSCAR RBAC groups..."
    run_octeliumctl "$dry_run" "$domain" apply --include-secret "$rendered_dir/octelium-secrets.yaml"
    run_octeliumctl "$dry_run" "$domain" apply "$rendered_dir/octelium-base.yaml"

    if [[ $with_authentik == true ]]; then
        cat >"$rendered_dir/octelium-idp.yaml" <<EOF
kind: Secret
metadata:
  name: oscar-authentik-client-secret
spec: {}
data:
  value: "$oidc_client_secret"
---
kind: IdentityProvider
metadata:
  name: authentik-sso
  displayName: Organization SSO (Authentik)
spec:
  displayName: Organization SSO (Authentik)
  oidc:
    issuerURL: https://auth.$domain/application/o/oscar-federation-sso/
    clientID: $oidc_client_id
    clientSecret:
      fromSecret: oscar-authentik-client-secret
    scopes:
      - openid
      - profile
      - email
      - groups
EOF
        chmod 0600 "$rendered_dir/octelium-idp.yaml"

        if [[ $dry_run != true ]]; then
            maybe_refresh_certbot_san "$domain" "auth.$domain" "$dry_run"
            info "Waiting for Authentik OIDC discovery endpoint (https://auth.$domain/application/o/oscar-federation-sso/.well-known/openid-configuration)..."
            for _ in $(seq 1 36); do
                if curl -fsSL --max-time 5 "https://auth.$domain/application/o/oscar-federation-sso/.well-known/openid-configuration" >/dev/null 2>&1; then
                    break
                fi
                sleep 5
            done
        fi
        info "Registering Authentik OIDC IdentityProvider in Octelium..."
        run_octeliumctl "$dry_run" "$domain" apply --include-secret "$rendered_dir/octelium-idp.yaml"
        if [[ $dry_run != true ]]; then
            install_sync_systemd_timer
            cmd_sync_users || true
        fi
    fi

    cat <<EOF

========================================================================
OSCAR Federation Hub Initialized ($domain)
========================================================================
Mode: $( [[ $with_authentik == true ]] && printf 'Octelium %s + Authentik %s Browser Admin GUI (%s)' "$OCTELIUM_VERSION" "$AUTHENTIK_VERSION" "$runtime" || printf 'Octelium %s Lightweight CLI Mode' "$OCTELIUM_VERSION" )

Next step — register each OSCAR server:
  ./oscar-hub.sh add-site north-gate --display-name "North Gate Portal" --with-trusted-headers
EOF

    if [[ $with_authentik == true ]]; then
        cat <<EOF

Authentik Browser User Console (create/remove users & assign groups here):
  Admin Console URL : https://auth.$domain/if/admin/
  Bootstrap User    : akadmin
  Bootstrap Secret  : stored in $secrets_dir/authentik-bootstrap-password.txt
  Pre-Created Groups: oscar-admins, oscar-operators, oscar-viewers

OSCAR Node "Users & Access -> Sign-In & SSO Policy" Settings:
  Enable OIDC SSO                  : ON
  Button Provider Name             : Organization SSO
  OIDC Issuer URL                  : https://auth.$domain/application/o/oscar-federation-sso/
  OIDC Client ID                   : $oidc_client_id
  OIDC Client Secret               : (see $secrets_dir/oidc-client-secret.txt)
  OIDC Scopes                      : openid profile email groups
  IdP Group -> Administrator       : oscar-admins
  IdP Group -> Operator            : oscar-operators
  External SSO User Console URL    : https://auth.$domain/if/admin/
========================================================================
EOF
    else
        cat <<EOF

Add a remote human operator in 1 command:
  ./oscar-hub.sh add-user jsmith --email jsmith@$domain --group oscar-operators
========================================================================
EOF
    fi
}

cmd_add_site() {
    require_initialized
    load_versions

    local site_slug="" display_name="" connector_user="" no_mint_token="false" with_trusted_headers="false" expire_in="90days" dry_run="false"
    if (($# > 0)) && [[ $1 != --* ]]; then
        site_slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
        shift
    fi
    while (($# > 0)); do
        case $1 in
            --display-name) display_name=${2:-}; shift 2 ;;
            --connector-user) connector_user=${2:-}; shift 2 ;;
            --no-mint-token) no_mint_token="true"; shift ;;
            --with-trusted-headers) with_trusted_headers="true"; shift ;;
            --expire-in) expire_in=${2:-}; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            *) fail "Unknown option for add-site: $1" ;;
        esac
    done

    [[ -n $site_slug ]] || fail "Site slug is required (e.g. ./oscar-hub.sh add-site north-gate)."
    valid_slug "$site_slug" || fail "Invalid site slug '$site_slug' (use lowercase letters, digits, and hyphens)."
    valid_duration "$expire_in" || fail "Invalid --expire-in '$expire_in' (examples: 30days, 90days, 6months)."
    if [[ -z $connector_user && $no_mint_token == true && -f "$sites_dir/$site_slug.yaml" ]]; then
        connector_user=$(awk '/^      user:/ { print $2; exit }' "$sites_dir/$site_slug.yaml")
    fi
    [[ -n $connector_user ]] || connector_user="oscar-node-$site_slug"
    valid_username "$connector_user" || fail "Invalid --connector-user '$connector_user'."
    [[ -n $display_name ]] || display_name="OSCAR Site ($site_slug)"
    [[ $display_name != *\"* && $display_name != *$'\n'* ]] || fail "Display name cannot contain quotes or newlines."

    local hub_domain with_authentik trusted_auth_block="" trusted_headers_block="" sandbox_trusted_headers_block=""
    hub_domain=$(read_kv "$config_file" HUB_DOMAIN)
    with_authentik=$(read_kv "$config_file" WITH_AUTHENTIK)

    if [[ $with_trusted_headers == true ]]; then
        trusted_auth_block=$(cat <<'EOF'
      auth:
        custom:
          header: X-Oscar-Tunnel-Secret
          value:
            fromSecret: oscar-tunnel-shared-secret
EOF
)
        trusted_headers_block=$(cat <<'EOF'
  dynamicConfig:
    rules:
      - condition:
          matchAny: true
        eval: |
          {
            "tls": {
              "insecureSkipVerify": true
            },
            "upstream": {
              "user": "__CONNECTOR_USER__",
              "url": "https://gateway:8443"
            },
            "http": {
              "auth": {
                "custom": {
                  "header": "X-Oscar-Tunnel-Secret",
                  "value": {
                    "fromSecret": "oscar-tunnel-shared-secret"
                  }
                }
              },
              "cors": {
                "allowClusterServices": true,
                "allowCredentials": true,
                "allowOriginStringMatch": ["*"],
                "allowMethods": "GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD",
                "allowHeaders": "Authorization, Content-Type, Accept, Origin, If-None-Match, X-OSCAR-HLS-Viewer",
                "exposeHeaders": "ETag, Content-Disposition",
                "maxAge": "1800"
              },
              "header": {
                "authorizationMode": "PASS",
                "host": { "preserve": true },
                "addRequestHeaders": [
                  {
                    "key": "X-Octelium-User",
                    "value": has(ctx.user) ? ctx.user.metadata.name : ""
                  },
                  {
                    "key": "X-Octelium-Groups",
                    "value": (has(ctx.user) && has(ctx.user.spec.groups) && "oscar-admins" in ctx.user.spec.groups ? "oscar-admins," : "") + (has(ctx.user) && has(ctx.user.spec.groups) && "oscar-operators" in ctx.user.spec.groups ? "oscar-operators," : "") + (has(ctx.user) && has(ctx.user.spec.groups) && "oscar-viewers" in ctx.user.spec.groups ? "oscar-viewers" : "")
                  }
                ]
              }
            }
          }
EOF
)
        sandbox_trusted_headers_block=$(cat <<'EOF'
  dynamicConfig:
    rules:
      - condition:
          matchAny: true
        eval: |
          {
            "upstream": {
              "user": "__CONNECTOR_USER__",
              "url": "http://127.0.0.1:18444"
            },
            "http": {
              "auth": {
                "custom": {
                  "header": "X-Oscar-Tunnel-Secret",
                  "value": {
                    "fromSecret": "oscar-tunnel-shared-secret"
                  }
                }
              },
              "cors": {
                "allowClusterServices": true,
                "allowCredentials": true,
                "allowOriginStringMatch": ["*"],
                "allowMethods": "GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD",
                "allowHeaders": "Authorization, Content-Type, Accept, Origin, If-None-Match, X-OSCAR-HLS-Viewer",
                "exposeHeaders": "ETag, Content-Disposition",
                "maxAge": "1800"
              },
              "header": {
                "authorizationMode": "PASS",
                "host": { "preserve": true },
                "addRequestHeaders": [
                  {
                    "key": "X-Octelium-User",
                    "value": has(ctx.user) ? ctx.user.metadata.name : ""
                  },
                  {
                    "key": "X-Octelium-Groups",
                    "value": (has(ctx.user) && has(ctx.user.spec.groups) && "oscar-admins" in ctx.user.spec.groups ? "oscar-admins," : "") + (has(ctx.user) && has(ctx.user.spec.groups) && "oscar-operators" in ctx.user.spec.groups ? "oscar-operators," : "") + (has(ctx.user) && has(ctx.user.spec.groups) && "oscar-viewers" in ctx.user.spec.groups ? "oscar-viewers" : "")
                  }
                ]
              }
            }
          }
EOF
)
    fi

    local esc_slug esc_display esc_conn site_manifest="$sites_dir/$site_slug.yaml" token_file="$tokens_dir/$site_slug.token"
    esc_slug=$(escape_sed_replacement "$site_slug")
    esc_display=$(escape_sed_replacement "$display_name")
    esc_conn=$(escape_sed_replacement "$connector_user")

    awk -v ab="$trusted_auth_block" -v hb="$trusted_headers_block" -v shb="$sandbox_trusted_headers_block" '{
        if ($0 == "__TRUSTED_AUTH_BLOCK__") {
            if (length(ab) > 0) print ab
        } else if ($0 == "__TRUSTED_HEADERS_BLOCK__") {
            if (length(hb) > 0) print hb
        } else if ($0 == "__SANDBOX_TRUSTED_HEADERS_BLOCK__") {
            if (length(shb) > 0) print shb
        } else {
            print $0
        }
    }' "$repo_root/templates/octelium-site.yaml.tmpl" \
        | sed -e "s/__SITE_SLUG__/$esc_slug/g" -e "s/__SITE_DISPLAY_NAME__/$esc_display/g" -e "s/__CONNECTOR_USER__/$esc_conn/g" >"$site_manifest"
    chmod 0600 "$site_manifest"

    info "Registering OSCAR site '$site_slug' ($site_slug.$hub_domain + $site_slug-sandbox.$hub_domain -> $connector_user) on Octelium..."
    run_octeliumctl "$dry_run" "$hub_domain" apply "$site_manifest"
    maybe_refresh_certbot_san "$hub_domain" "$site_slug.$hub_domain" "$dry_run"
    maybe_refresh_certbot_san "$hub_domain" "$site_slug-sandbox.$hub_domain" "$dry_run"

    if [[ $no_mint_token != true ]]; then
        if [[ $dry_run == true ]]; then
            printf 'dry-run-token-%s\n' "$site_slug" >"$token_file"
            chmod 0600 "$token_file"
        else
            OCTELIUM_DOMAIN="$hub_domain" octeliumctl create cred --user "$connector_user" --expire-in "$expire_in" >"$token_file"
            chmod 0600 "$token_file"
        fi
    fi

    cat <<EOF

========================================================================
Site Registered:          https://$site_slug.$hub_domain
Practice Sandbox Tunnel:  https://$site_slug-sandbox.$hub_domain
========================================================================
EOF
    if [[ $no_mint_token != true ]]; then
        cat <<EOF
Connector Token File (copy securely to the OSCAR server, mode 0600):
  $token_file

1) Run on a Linux OSCAR 3.11.0+ server:
   sudo bash oscar-remote-access.sh configure \\
     --domain $hub_domain \\
     --service $site_slug \\
     --token-file /path/to/$site_slug.token

2) Or run on a Windows 11 OSCAR 3.11.0+ server (Administrator PowerShell):
   .\\oscar-remote-access.ps1 configure \`
     -Domain $hub_domain \`
     -Service $site_slug \`
     -TokenFile C:\\path\\to\\$site_slug.token
EOF
    else
        printf 'Existing workload connector (%s) preserved without rotating token.\n' "$connector_user"
    fi

    if [[ $with_authentik == true ]]; then
        cat <<EOF

3) OIDC Callback URL pre-authorized by Blueprint regex:
   https://$site_slug.$hub_domain/login/oidc/callback
EOF
    fi
    if [[ $with_trusted_headers == true ]]; then
        cat <<EOF

4) Optional Zero-Click Trusted Tunnel SSO (OSCAR -> Sign-In & SSO Policy):
   Enable Verified Tunnel Header SSO : ON
   Verified User Header              : X-Octelium-User
   Verified Groups Header            : X-Octelium-Groups
   Tunnel Shared Secret              : (see $secrets_dir/oscar-tunnel-shared-secret.txt)
EOF
    fi
    printf '========================================================================\n'
}

cmd_remove_site() {
    require_initialized
    load_versions
    local site_slug="" connector_user="" dry_run="false"
    if (($# > 0)) && [[ $1 != --* ]]; then
        site_slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
        shift
    fi
    while (($# > 0)); do
        case $1 in
            --connector-user) connector_user=${2:-}; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            *) fail "Unknown option for remove-site: $1" ;;
        esac
    done
    [[ -n $site_slug ]] || fail "Site slug is required."
    valid_slug "$site_slug" || fail "Invalid site slug: $site_slug"
    [[ -n $connector_user ]] || connector_user="oscar-node-$site_slug"
    valid_username "$connector_user" || fail "Invalid --connector-user: $connector_user"

    local hub_domain
    hub_domain=$(read_kv "$config_file" HUB_DOMAIN)
    info "Removing Octelium Services '$site_slug' / '$site_slug-sandbox' and Workload User '$connector_user'..."
    run_octeliumctl "$dry_run" "$hub_domain" delete service "$site_slug"
    run_octeliumctl "$dry_run" "$hub_domain" delete service "$site_slug-sandbox" || true
    run_octeliumctl "$dry_run" "$hub_domain" delete user "$connector_user"
    rm -f -- "$sites_dir/$site_slug.yaml" "$tokens_dir/$site_slug.token"
    info "Removed site '$site_slug'."
}

cmd_sync_users() {
    require_initialized
    load_versions
    local dry_run="false"
    while (($# > 0)); do
        case $1 in
            --dry-run) dry_run="true"; shift ;;
            *) fail "Unknown option for sync-users: $1" ;;
        esac
    done

    local hub_domain with_authentik sync_token users_json sync_manifest="$rendered_dir/synced-authentik-users.yaml"
    hub_domain=$(read_kv "$config_file" HUB_DOMAIN)
    with_authentik=$(read_kv "$config_file" WITH_AUTHENTIK)
    [[ $with_authentik == true ]] || fail "sync-users requires --with-authentik mode."
    sync_token=$(<"$secrets_dir/authentik-sync-token.txt")

    if [[ $dry_run == true ]]; then
        info "[dry-run] Would query https://auth.$hub_domain/api/v3/core/users/ and reconcile HUMAN users into Octelium."
        return 0
    fi

    users_json=$(curl -fsSL --max-time 15 \
        -H "Authorization: Bearer $sync_token" \
        "https://auth.$hub_domain/api/v3/core/users/?page_size=500") || fail "Could not query Authentik users API."

    local active_names_file="$rendered_dir/synced-authentik-usernames.txt"
    python3 - "$users_json" "$sync_manifest" "$active_names_file" <<'PY'
import json, re, sys

payload = json.loads(sys.argv[1])
out_path = sys.argv[2]
names_path = sys.argv[3]
allowed_groups = {"oscar-admins", "oscar-operators", "oscar-viewers"}
docs = []
active_names = []

for u in payload.get("results", []):
    if u.get("type") not in (None, "internal", "external"):
        continue
    if not u.get("is_active", True):
        continue
    raw_username = (u.get("username") or "").strip().lower()
    email = (u.get("email") or "").strip()
    if raw_username in ("", "akadmin", "root", "octelium") or not email:
        continue
    safe_name = re.sub(r"[^a-z0-9._-]", "-", raw_username).strip(".-_")
    if not safe_name:
        continue
    groups = sorted(
        g.get("name")
        for g in (u.get("groups_obj") or [])
        if isinstance(g, dict) and g.get("name") in allowed_groups
    )
    if not groups:
        continue
    active_names.append(safe_name)
    group_lines = "\n".join(f"    - {g}" for g in groups)
    docs.append(
        f"kind: User\n"
        f"metadata:\n"
        f"  name: {safe_name}\n"
        f"  labels:\n"
        f"    managed-by: authentik-sync\n"
        f"spec:\n"
        f"  type: HUMAN\n"
        f"  email: {email}\n"
        f"  isDisabled: false\n"
        f"  groups:\n"
        f"{group_lines}\n"
    )

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("---\n".join(docs))
with open(names_path, "w", encoding="utf-8") as nfh:
    nfh.write("\n".join(sorted(set(active_names))) + ("\n" if active_names else ""))
PY
    chmod 0600 "$sync_manifest" "$active_names_file"
    if [[ -s $sync_manifest ]]; then
        run_octeliumctl "false" "$hub_domain" apply "$sync_manifest"
    fi

    # Prune any Authentik-managed Octelium HUMAN users that were deleted, disabled, or stripped of OSCAR groups
    local octelium_users_json stale_user
    if octelium_users_json=$(OCTELIUM_DOMAIN="$hub_domain" octeliumctl get user -o json 2>/dev/null); then
        while IFS= read -r stale_user; do
            [[ -n $stale_user ]] || continue
            info "Revoking deleted/deactivated Authentik user '$stale_user' from Octelium..."
            run_octeliumctl "false" "$hub_domain" delete user "$stale_user" || true
        done < <(
            python3 - "$octelium_users_json" "$active_names_file" <<'PY'
import json, sys

oct_data = json.loads(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as fh:
    active = {line.strip() for line in fh if line.strip()}

for item in oct_data.get("items", []):
    spec = item.get("spec") or {}
    meta = item.get("metadata") or {}
    name = (meta.get("name") or "").strip()
    labels = meta.get("labels") or {}
    if spec.get("type") != "HUMAN" or not name:
        continue
    if labels.get("managed-by") == "authentik-sync" and name not in active:
        print(name)
PY
        )
    fi
}

cmd_add_user() {
    require_initialized
    load_versions
    local username="" email="" group="oscar-operators" expire_in="30days" dry_run="false"
    if (($# > 0)) && [[ $1 != --* ]]; then
        username=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
        shift
    fi
    while (($# > 0)); do
        case $1 in
            --email) email=${2:-}; shift 2 ;;
            --group) group=${2:-}; shift 2 ;;
            --expire-in) expire_in=${2:-}; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            *) fail "Unknown option for add-user: $1" ;;
        esac
    done

    [[ -n $username ]] || fail "Username is required."
    valid_username "$username" || fail "Invalid username: $username"
    [[ -n $email ]] || fail "--email <user@org.tld> is required."
    valid_email "$email" || fail "Invalid email: $email"
    case $group in
        oscar-admins|oscar-operators|oscar-viewers) ;;
        *) fail "Invalid --group '$group' (use oscar-admins, oscar-operators, or oscar-viewers)." ;;
    esac
    valid_duration "$expire_in" || fail "Invalid --expire-in: $expire_in"

    local hub_domain user_manifest="$rendered_dir/user-$username.yaml"
    hub_domain=$(read_kv "$config_file" HUB_DOMAIN)
    cat >"$user_manifest" <<EOF
kind: User
metadata:
  name: $username
spec:
  type: HUMAN
  email: $email
  groups:
    - $group
EOF
    chmod 0600 "$user_manifest"

    info "Applying Octelium HUMAN user '$username' (group: $group)..."
    run_octeliumctl "$dry_run" "$hub_domain" apply "$user_manifest"
    info "Minting clientless browser sign-in credential ($expire_in) for https://$hub_domain/login :"
    run_octeliumctl "$dry_run" "$hub_domain" create cred --user "$username" --session-type clientless --expire-in "$expire_in"
}

cmd_remove_user() {
    require_initialized
    load_versions
    local username="" dry_run="false"
    if (($# > 0)) && [[ $1 != --* ]]; then
        username=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
        shift
    fi
    while (($# > 0)); do
        case $1 in
            --dry-run) dry_run="true"; shift ;;
            *) fail "Unknown option for remove-user: $1" ;;
        esac
    done
    [[ -n $username ]] || fail "Username is required."
    valid_username "$username" || fail "Invalid username: $username"
    local hub_domain
    hub_domain=$(read_kv "$config_file" HUB_DOMAIN)
    run_octeliumctl "$dry_run" "$hub_domain" delete user "$username"
    rm -f -- "$rendered_dir/user-$username.yaml"
    info "Revoked Octelium user '$username'."
}

cmd_status() {
    require_initialized
    load_versions
    local hub_domain with_authentik runtime
    hub_domain=$(read_kv "$config_file" HUB_DOMAIN)
    with_authentik=$(read_kv "$config_file" WITH_AUTHENTIK)
    runtime=$(read_kv "$config_file" AUTHENTIK_RUNTIME)
    printf 'Hub Domain       : %s\n' "$hub_domain"
    printf 'Octelium Pin     : %s\n' "$OCTELIUM_VERSION"
    printf 'Authentik Enabled: %s (pin: %s, runtime: %s)\n' "$with_authentik" "$AUTHENTIK_VERSION" "${runtime:-auto}"
    printf 'Registered Sites :\n'
    local found=false
    for site_file in "$sites_dir"/*.yaml; do
        [[ -f $site_file ]] || continue
        found=true
        local slug=${site_file##*/}
        slug=${slug%.yaml}
        printf '  - %s (https://%s.%s | sandbox: https://%s-sandbox.%s)\n' "$slug" "$slug" "$hub_domain" "$slug" "$hub_domain"
    done
    [[ $found == true ]] || printf '  (none yet — run ./oscar-hub.sh add-site <slug>)\n'

    if [[ $with_authentik == true ]]; then
        if [[ $runtime == k8s ]] && command -v kubectl >/dev/null 2>&1; then
            kubectl -n oscar-authentik get pods 2>/dev/null || true
        elif [[ -f "$state_dir/authentik.env" ]] && command -v docker >/dev/null 2>&1; then
            docker compose --project-name oscar-hub-sso \
                --env-file "$state_dir/authentik.env" \
                --file "$repo_root/compose.authentik.yaml" \
                ps || true
        fi
    fi
}

cmd_upgrade() {
    require_initialized
    load_versions
    local dry_run="false"
    while (($# > 0)); do
        case $1 in
            --dry-run) dry_run="true"; shift ;;
            *) fail "Unknown option for upgrade: $1" ;;
        esac
    done
    local with_authentik runtime
    with_authentik=$(read_kv "$config_file" WITH_AUTHENTIK)
    runtime=$(read_kv "$config_file" AUTHENTIK_RUNTIME)
    if [[ $with_authentik == true ]]; then
        if [[ $runtime == k8s ]]; then
            if [[ $dry_run == true ]]; then
                info "[dry-run] Would update K3s Authentik images to $AUTHENTIK_VERSION."
            else
                kubectl -n oscar-authentik set image deploy/authentik-server server="ghcr.io/goauthentik/server:$AUTHENTIK_VERSION"
                kubectl -n oscar-authentik set image deploy/authentik-worker worker="ghcr.io/goauthentik/server:$AUTHENTIK_VERSION"
                kubectl -n oscar-authentik rollout status deploy/authentik-server --timeout=300s
                kubectl -n oscar-authentik rollout status deploy/authentik-worker --timeout=300s
            fi
        elif [[ -f "$state_dir/authentik.env" ]]; then
            sed -i.bak \
                -e "s/^POSTGRES_VERSION=.*/POSTGRES_VERSION=$POSTGRES_VERSION/" \
                -e "s/^REDIS_VERSION=.*/REDIS_VERSION=$REDIS_VERSION/" \
                -e "s/^AUTHENTIK_VERSION=.*/AUTHENTIK_VERSION=$AUTHENTIK_VERSION/" \
                "$state_dir/authentik.env"
            rm -f -- "$state_dir/authentik.env.bak"
            if [[ $dry_run == true ]]; then
                info "[dry-run] Would pull and recreate Authentik $AUTHENTIK_VERSION containers."
            else
                docker compose --project-name oscar-hub-sso \
                    --env-file "$state_dir/authentik.env" \
                    --file "$repo_root/compose.authentik.yaml" \
                    pull
                docker compose --project-name oscar-hub-sso \
                    --env-file "$state_dir/authentik.env" \
                    --file "$repo_root/compose.authentik.yaml" \
                    up --detach --wait
            fi
        fi
    fi
    info "Hub configuration synchronized with versions.env (Octelium $OCTELIUM_VERSION / Authentik $AUTHENTIK_VERSION)."
}

subcommand=${1:-}
(($# > 0)) && shift || true
case $subcommand in
    init) cmd_init "$@" ;;
    add-site) cmd_add_site "$@" ;;
    remove-site) cmd_remove_site "$@" ;;
    sync-users) cmd_sync_users "$@" ;;
    add-user) cmd_add_user "$@" ;;
    remove-user) cmd_remove_user "$@" ;;
    status) cmd_status "$@" ;;
    upgrade) cmd_upgrade "$@" ;;
    -h|--help|"") usage ;;
    *) fail "Unknown command '$subcommand'. Run ./oscar-hub.sh --help for usage." ;;
esac
