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
    local dry_run=$1
    shift
    if [[ $dry_run == true ]]; then
        printf '[dry-run] octeliumctl %s\n' "$*"
        return 0
    fi
    command -v octeliumctl >/dev/null 2>&1 || fail "octeliumctl is not installed on PATH. Install octeliumctl ${OCTELIUM_VERSION} on this Hub host first."
    octeliumctl "$@"
}

usage() {
    cat <<'EOF'
Usage: ./oscar-hub.sh <command> [options]

Commands:
  init        Initialize the Hub configuration, secrets, and optional Authentik SSO stack
              Options:
                --domain <hub.example.org>      Base Hub domain (required)
                --with-authentik                Deploy Authentik browser SSO & pre-wired OSCAR groups
                --admin-email <admin@org.tld>   Bootstrap email for Authentik akadmin (default: admin@<domain>)
                --bind-address <ip>             Authentik bind IP (default: 127.0.0.1 behind reverse proxy)
                --dry-run                       Render configs and secrets without invoking Docker or octeliumctl

  add-site    Register a federated OSCAR server and mint its scoped outbound connector token
              Options:
                <site-slug>                     DNS-safe site name (e.g. north-gate -> north-gate.<domain>)
                --display-name "<Label>"        Human-readable site title
                --with-trusted-headers          Inject X-Oscar-Tunnel-Secret, X-Octelium-User & X-Octelium-Groups
                --expire-in <duration>          Connector token validity (default: 90days)
                --dry-run                       Render manifests without invoking octeliumctl

  remove-site Remove a federated OSCAR site service and revoke its workload connector
              Options:
                <site-slug>                     Site slug to remove
                --dry-run                       Preview removal commands

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

  status      Show Hub configuration, registered OSCAR sites, and Authentik container health
  upgrade     Pull pinned container versions from versions.env and rolling-restart Authentik
EOF
}

cmd_init() {
    local domain="" with_authentik="false" admin_email="" bind_address="127.0.0.1" dry_run="false"
    while (($# > 0)); do
        case $1 in
            --domain) domain=${2:-}; shift 2 ;;
            --with-authentik) with_authentik="true"; shift ;;
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
    mkdir -p "$secrets_dir" "$tokens_dir" "$rendered_dir" "$sites_dir"
    chmod 0700 "$state_dir" "$secrets_dir" "$tokens_dir" "$rendered_dir" "$sites_dir"

    local oidc_client_id="oscar-federation-hub"
    local oidc_client_secret pg_pass ak_secret ak_bootstrap tunnel_shared_secret
    if [[ -f "$secrets_dir/oidc-client-secret.txt" ]]; then
        oidc_client_secret=$(<"$secrets_dir/oidc-client-secret.txt")
    else
        oidc_client_secret=$(random_hex 24)
        printf '%s\n' "$oidc_client_secret" >"$secrets_dir/oidc-client-secret.txt"
    fi
    if [[ -f "$secrets_dir/authentik-postgres-password.txt" ]]; then
        pg_pass=$(<"$secrets_dir/authentik-postgres-password.txt")
    else
        pg_pass=$(random_hex 24)
        printf '%s\n' "$pg_pass" >"$secrets_dir/authentik-postgres-password.txt"
    fi
    if [[ -f "$secrets_dir/authentik-secret-key.txt" ]]; then
        ak_secret=$(<"$secrets_dir/authentik-secret-key.txt")
    else
        ak_secret=$(random_hex 32)
        printf '%s\n' "$ak_secret" >"$secrets_dir/authentik-secret-key.txt"
    fi
    if [[ -f "$secrets_dir/authentik-bootstrap-password.txt" ]]; then
        ak_bootstrap=$(<"$secrets_dir/authentik-bootstrap-password.txt")
    else
        ak_bootstrap=$(random_hex 16)
        printf '%s\n' "$ak_bootstrap" >"$secrets_dir/authentik-bootstrap-password.txt"
    fi
    if [[ -f "$secrets_dir/oscar-tunnel-shared-secret.txt" ]]; then
        tunnel_shared_secret=$(<"$secrets_dir/oscar-tunnel-shared-secret.txt")
    else
        tunnel_shared_secret=$(random_hex 24)
        printf '%s\n' "$tunnel_shared_secret" >"$secrets_dir/oscar-tunnel-shared-secret.txt"
    fi
    chmod 0600 "$secrets_dir"/*.txt

    cat >"$config_file" <<EOF
HUB_DOMAIN=$domain
WITH_AUTHENTIK=$with_authentik
ADMIN_EMAIL=$admin_email
OIDC_CLIENT_ID=$oidc_client_id
AUTHENTIK_BIND_ADDRESS=$bind_address
EOF
    chmod 0600 "$config_file"

    local idp_block=""
    if [[ $with_authentik == true ]]; then
        local esc_domain esc_secret esc_regex_domain
        esc_domain=$(escape_sed_replacement "$domain")
        esc_secret=$(escape_sed_replacement "$oidc_client_secret")
        esc_regex_domain=$(escape_sed_replacement "$(printf '%s' "$domain" | sed -e 's/\./\\./g')")

        sed \
            -e "s/__HUB_DOMAIN__/$esc_domain/g" \
            -e "s/__HUB_DOMAIN_ESCAPED__/$esc_regex_domain/g" \
            -e "s/__OIDC_CLIENT_ID__/$oidc_client_id/g" \
            -e "s/__OIDC_CLIENT_SECRET__/$esc_secret/g" \
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
AUTHENTIK_BIND_ADDRESS=$bind_address
AUTHENTIK_BLUEPRINT_FILE=$rendered_dir/oscar-federation.yaml
EOF
        chmod 0600 "$state_dir/authentik.env"

        idp_block=$(cat <<EOF
---
kind: IdentityProvider
metadata:
  name: authentik-sso
  displayName: Organization SSO (Authentik)
spec:
  oidc:
    issuerURL: https://auth.$domain/application/o/oscar-federation-sso/
    clientID: $oidc_client_id
    clientSecret: $oidc_client_secret
    scopes:
      - openid
      - profile
      - email
      - groups
EOF
)
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

    awk -v block="$idp_block" '{
        if ($0 == "__AUTHENTIK_IDP_BLOCK__") {
            if (length(block) > 0) print block
        } else {
            print $0
        }
    }' "$repo_root/templates/octelium-base-resources.yaml.tmpl" >"$rendered_dir/octelium-base.yaml"
    chmod 0600 "$rendered_dir/octelium-base.yaml"

    info "Applying base Octelium policies and OSCAR RBAC groups..."
    run_octeliumctl "$dry_run" apply -f "$rendered_dir/octelium-base.yaml"

    cat <<EOF

========================================================================
OSCAR Federation Hub Initialized ($domain)
========================================================================
Mode: $( [[ $with_authentik == true ]] && printf 'Octelium %s + Authentik %s Browser Admin GUI' "$OCTELIUM_VERSION" "$AUTHENTIK_VERSION" || printf 'Octelium %s Lightweight CLI Mode' "$OCTELIUM_VERSION" )

Next step — register each OSCAR server:
  ./oscar-hub.sh add-site north-gate --display-name "North Gate Portal"
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

    local site_slug="" display_name="" with_trusted_headers="false" expire_in="90days" dry_run="false"
    if (($# > 0)) && [[ $1 != --* ]]; then
        site_slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
        shift
    fi
    while (($# > 0)); do
        case $1 in
            --display-name) display_name=${2:-}; shift 2 ;;
            --with-trusted-headers) with_trusted_headers="true"; shift ;;
            --expire-in) expire_in=${2:-}; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            *) fail "Unknown option for add-site: $1" ;;
        esac
    done

    [[ -n $site_slug ]] || fail "Site slug is required (e.g. ./oscar-hub.sh add-site north-gate)."
    valid_slug "$site_slug" || fail "Invalid site slug '$site_slug' (use lowercase letters, digits, and hyphens)."
    valid_duration "$expire_in" || fail "Invalid --expire-in '$expire_in' (examples: 30days, 90days, 6months)."
    [[ -n $display_name ]] || display_name="OSCAR Site ($site_slug)"
    [[ $display_name != *\"* && $display_name != *$'\n'* ]] || fail "Display name cannot contain quotes or newlines."

    local hub_domain with_authentik tunnel_secret trusted_block=""
    hub_domain=$(read_kv "$config_file" HUB_DOMAIN)
    with_authentik=$(read_kv "$config_file" WITH_AUTHENTIK)
    tunnel_secret=$(<"$secrets_dir/oscar-tunnel-shared-secret.txt")

    if [[ $with_trusted_headers == true ]]; then
        trusted_block=$(cat <<EOF
        set:
          X-Oscar-Tunnel-Secret: "$tunnel_secret"
        fromContext:
          X-Octelium-User: "ctx.user.metadata.name"
          X-Octelium-Groups: "ctx.user.spec.groups"
EOF
)
    fi

    local esc_slug esc_display site_manifest="$sites_dir/$site_slug.yaml" token_file="$tokens_dir/$site_slug.token"
    esc_slug=$(escape_sed_replacement "$site_slug")
    esc_display=$(escape_sed_replacement "$display_name")

    awk -v tb="$trusted_block" '{
        if ($0 == "__TRUSTED_HEADERS_BLOCK__") {
            if (length(tb) > 0) print tb
        } else {
            print $0
        }
    }' "$repo_root/templates/octelium-site.yaml.tmpl" \
        | sed -e "s/__SITE_SLUG__/$esc_slug/g" -e "s/__SITE_DISPLAY_NAME__/$esc_display/g" >"$site_manifest"
    chmod 0600 "$site_manifest"

    info "Registering OSCAR site '$site_slug' ($site_slug.$hub_domain) on Octelium..."
    run_octeliumctl "$dry_run" apply -f "$site_manifest"

    if [[ $dry_run == true ]]; then
        printf 'dry-run-token-%s\n' "$site_slug" >"$token_file"
        chmod 0600 "$token_file"
    else
        octeliumctl create cred --user "oscar-node-$site_slug" --expire-in "$expire_in" >"$token_file"
        chmod 0600 "$token_file"
    fi

    cat <<EOF

========================================================================
Site Registered: https://$site_slug.$hub_domain
========================================================================
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
    local site_slug="" dry_run="false"
    if (($# > 0)) && [[ $1 != --* ]]; then
        site_slug=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
        shift
    fi
    while (($# > 0)); do
        case $1 in
            --dry-run) dry_run="true"; shift ;;
            *) fail "Unknown option for remove-site: $1" ;;
        esac
    done
    [[ -n $site_slug ]] || fail "Site slug is required."
    valid_slug "$site_slug" || fail "Invalid site slug: $site_slug"

    info "Removing Octelium Service '$site_slug' and Workload User 'oscar-node-$site_slug'..."
    run_octeliumctl "$dry_run" delete service "$site_slug"
    run_octeliumctl "$dry_run" delete user "oscar-node-$site_slug"
    rm -f -- "$sites_dir/$site_slug.yaml" "$tokens_dir/$site_slug.token"
    info "Removed site '$site_slug'."
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
    run_octeliumctl "$dry_run" apply -f "$user_manifest"
    info "Minting clientless browser sign-in credential ($expire_in) for https://$hub_domain/login :"
    run_octeliumctl "$dry_run" create cred --user "$username" --session-type clientless --expire-in "$expire_in"
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
    run_octeliumctl "$dry_run" delete user "$username"
    rm -f -- "$rendered_dir/user-$username.yaml"
    info "Revoked Octelium user '$username'."
}

cmd_status() {
    require_initialized
    load_versions
    local hub_domain with_authentik
    hub_domain=$(read_kv "$config_file" HUB_DOMAIN)
    with_authentik=$(read_kv "$config_file" WITH_AUTHENTIK)
    printf 'Hub Domain       : %s\n' "$hub_domain"
    printf 'Octelium Pin     : %s\n' "$OCTELIUM_VERSION"
    printf 'Authentik Enabled: %s (pin: %s)\n' "$with_authentik" "$AUTHENTIK_VERSION"
    printf 'Registered Sites :\n'
    local found=false
    for site_file in "$sites_dir"/*.yaml; do
        [[ -f $site_file ]] || continue
        found=true
        local slug=${site_file##*/}
        slug=${slug%.yaml}
        printf '  - %s (https://%s.%s)\n' "$slug" "$slug" "$hub_domain"
    done
    [[ $found == true ]] || printf '  (none yet — run ./oscar-hub.sh add-site <slug>)\n'

    if [[ $with_authentik == true ]] && [[ -f "$state_dir/authentik.env" ]] && command -v docker >/dev/null 2>&1; then
        docker compose --project-name oscar-hub-sso \
            --env-file "$state_dir/authentik.env" \
            --file "$repo_root/compose.authentik.yaml" \
            ps || true
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
    local with_authentik
    with_authentik=$(read_kv "$config_file" WITH_AUTHENTIK)
    if [[ $with_authentik == true ]] && [[ -f "$state_dir/authentik.env" ]]; then
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
    info "Hub configuration synchronized with versions.env (Octelium $OCTELIUM_VERSION / Authentik $AUTHENTIK_VERSION)."
}

subcommand=${1:-}
(($# > 0)) && shift || true
case $subcommand in
    init) cmd_init "$@" ;;
    add-site) cmd_add_site "$@" ;;
    remove-site) cmd_remove_site "$@" ;;
    add-user) cmd_add_user "$@" ;;
    remove-user) cmd_remove_user "$@" ;;
    status) cmd_status "$@" ;;
    upgrade) cmd_upgrade "$@" ;;
    -h|--help|"") usage ;;
    *) fail "Unknown command '$subcommand'. Run ./oscar-hub.sh --help for usage." ;;
esac
