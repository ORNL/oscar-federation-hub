#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)

tmp_root=$(mktemp -d)
cleanup() {
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT

assert_file_mode() {
    local file=$1 expected=$2 actual
    [[ -f $file ]] || { printf 'FAIL: expected file %s\n' "$file" >&2; exit 1; }
    actual=$(stat -c '%a' "$file")
    [[ $actual == "$expected" ]] || {
        printf 'FAIL: %s mode=%s expected=%s\n' "$file" "$actual" "$expected" >&2
        exit 1
    }
}

assert_contains() {
    local file=$1 pattern=$2
    grep -Fq -- "$pattern" "$file" || {
        printf 'FAIL: %s did not contain %s\n' "$file" "$pattern" >&2
        exit 1
    }
}

printf '1. Testing Mode A (--with-authentik --runtime k8s --dry-run) lifecycle...\n'
state_a="$tmp_root/state-authentik"
OSCAR_HUB_STATE_DIR="$state_a" bash "$repo_root/oscar-hub.sh" init \
    --domain hub.example.org \
    --with-authentik \
    --runtime k8s \
    --admin-email secops@example.org \
    --dry-run >/dev/null

assert_file_mode "$state_a/hub.env" 600
assert_file_mode "$state_a/authentik.env" 600
assert_file_mode "$state_a/secrets/oidc-client-secret.txt" 600
assert_file_mode "$state_a/secrets/oscar-tunnel-shared-secret.txt" 600
assert_file_mode "$state_a/rendered/oscar-federation.yaml" 600
assert_file_mode "$state_a/rendered/k8s-authentik.yaml" 600
assert_file_mode "$state_a/rendered/octelium-base.yaml" 600
assert_file_mode "$state_a/rendered/octelium-idp.yaml" 600

assert_contains "$state_a/rendered/octelium-base.yaml" "url: https://authentik-server.oscar-authentik.svc:9443"
assert_contains "$state_a/rendered/octelium-idp.yaml" "issuerURL: https://auth.hub.example.org/application/o/oscar-federation-sso/"
assert_contains "$state_a/rendered/octelium-idp.yaml" "fromSecret: oscar-authentik-client-secret"
assert_contains "$state_a/rendered/oscar-federation.yaml" "name: oscar-admins"
assert_contains "$state_a/rendered/oscar-federation.yaml" "name: oscar-operators"
assert_contains "$state_a/rendered/oscar-federation.yaml" "name: oscar-viewers"
assert_contains "$state_a/rendered/oscar-federation.yaml" "https://hub.example.org/callback"
assert_contains "$state_a/rendered/oscar-federation.yaml" 'https://[a-z0-9-]+\.hub\.example\.org/login/oidc/callback'

if command -v docker >/dev/null 2>&1; then
    docker compose --project-name oscar-hub-test \
        --env-file "$state_a/authentik.env" \
        --file "$repo_root/compose.authentik.yaml" \
        config -q
fi

OSCAR_HUB_STATE_DIR="$state_a" bash "$repo_root/oscar-hub.sh" add-site north-gate \
    --display-name "North Gate Portal" \
    --with-trusted-headers \
    --expire-in 90days \
    --dry-run >/dev/null

assert_file_mode "$state_a/sites/north-gate.yaml" 600
assert_file_mode "$state_a/tokens/north-gate.token" 600
assert_contains "$state_a/sites/north-gate.yaml" "mode: WEB"
assert_contains "$state_a/sites/north-gate.yaml" "allowClusterServices: true"
assert_contains "$state_a/sites/north-gate.yaml" '"allowClusterServices": true'
assert_contains "$state_a/sites/north-gate.yaml" "name: north-gate-sandbox"
assert_contains "$state_a/sites/north-gate.yaml" "url: http://127.0.0.1:18444"
assert_contains "$state_a/sites/north-gate.yaml" "fromSecret: oscar-tunnel-shared-secret"
assert_contains "$state_a/sites/north-gate.yaml" '"key": "X-Octelium-User"'
assert_contains "$state_a/sites/north-gate.yaml" '"key": "X-Octelium-Groups"'

status_out=$(OSCAR_HUB_STATE_DIR="$state_a" bash "$repo_root/oscar-hub.sh" status)
grep -Fq -- "https://north-gate.hub.example.org" <<<"$status_out"
grep -Fq -- "https://north-gate-sandbox.hub.example.org" <<<"$status_out"

OSCAR_HUB_STATE_DIR="$state_a" bash "$repo_root/oscar-hub.sh" sync-users --dry-run >/dev/null
OSCAR_HUB_STATE_DIR="$state_a" bash "$repo_root/oscar-hub.sh" upgrade --dry-run >/dev/null
OSCAR_HUB_STATE_DIR="$state_a" bash "$repo_root/oscar-hub.sh" remove-site north-gate --dry-run >/dev/null
[[ ! -e "$state_a/sites/north-gate.yaml" && ! -e "$state_a/tokens/north-gate.token" ]] || {
    printf 'FAIL: remove-site left residual site or token files\n' >&2
    exit 1
}

printf '2. Testing Mode B (lightweight octeliumctl-only --dry-run) lifecycle...\n'
state_b="$tmp_root/state-cli"
OSCAR_HUB_STATE_DIR="$state_b" bash "$repo_root/oscar-hub.sh" init \
    --domain hub.example.org \
    --dry-run >/dev/null

if grep -Fq -- "name: auth" "$state_b/rendered/octelium-base.yaml"; then
    printf 'FAIL: lightweight mode unexpectedly rendered Authentik auth service\n' >&2
    exit 1
fi

OSCAR_HUB_STATE_DIR="$state_b" bash "$repo_root/oscar-hub.sh" add-user jsmith \
    --email jsmith@example.org \
    --group oscar-operators \
    --expire-in 30days \
    --dry-run >/dev/null
assert_file_mode "$state_b/rendered/user-jsmith.yaml" 600
assert_contains "$state_b/rendered/user-jsmith.yaml" "- oscar-operators"

OSCAR_HUB_STATE_DIR="$state_b" bash "$repo_root/oscar-hub.sh" remove-user jsmith --dry-run >/dev/null
[[ ! -e "$state_b/rendered/user-jsmith.yaml" ]] || {
    printf 'FAIL: remove-user left residual user manifest\n' >&2
    exit 1
}

printf '3. Testing input validation fail-closed behavior...\n'
if OSCAR_HUB_STATE_DIR="$state_b" bash "$repo_root/oscar-hub.sh" add-site "../bad" --dry-run >/dev/null 2>&1; then
    printf 'FAIL: invalid site slug should have been rejected\n' >&2
    exit 1
fi
if OSCAR_HUB_STATE_DIR="$state_b" bash "$repo_root/oscar-hub.sh" add-user jsmith --email jsmith@example.org --group root --dry-run >/dev/null 2>&1; then
    printf 'FAIL: invalid group should have been rejected\n' >&2
    exit 1
fi

printf 'PASS: All oscar-federation-hub contract tests succeeded.\n'
