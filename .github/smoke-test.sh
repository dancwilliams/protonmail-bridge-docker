#!/bin/bash
#
# Start the image for real and check what a build alone cannot: that a working
# container reports healthy, that the healthcheck itself does not make the
# bridge log errors, that losing a served port reports unhealthy, and that
# `docker stop` ends the container without a SIGKILL.
#
# No Proton account is needed: the bridge serves SMTP/IMAP with no account
# logged in. Run once per connection mode, because the healthcheck from #105
# only spoke plaintext and failed every container in SSL mode (#116).
#
# A third run starts the same image as uid 1000 (opt-in non-root) and checks
# that the bridge really runs unprivileged. Before that, a few quick entrypoint
# runs check the non-root ownership guard on its own: it must reject root-owned
# bridge state and accept a root-owned certs mount and a Kubernetes fsGroup volume.
#
# Usage: smoke-test.sh <image>

set -euo pipefail

image=$1
name=smoke-$$

cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker volume rm "$name" "$name-certs" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
    echo "FAIL [$mode]: $1"
    docker inspect -f '{{range .State.Health.Log}}{{.ExitCode}} {{.Output}}{{println}}{{end}}' "$name" || true
    docker logs --tail 40 "$name" || true
    exit 1
}

health() { docker inspect -f '{{.State.Health.Status}}' "$name"; }

# Wait for a health status. The image's 60s start period stays in place, so
# "healthy" needs one passing check and a broken check needs the start period
# plus three failures to turn "unhealthy" -- hence the generous limit.
wait_health() {
    local want=$1 limit=$2 status
    for _ in $(seq "$limit"); do
        status=$(health)
        [ "$status" = "$want" ] && return 0
        [ "$want" = healthy ] && [ "$status" = unhealthy ] && break
        sleep 1
    done
    fail "expected $want, container is $status"
}

# Errors the bridge logs when a probe talks to it the wrong way: the wrong
# protocol for the mode, or a connection dropped mid-conversation.
probe_errors() { docker logs "$name" 2>&1 | grep -E 'ERRO.*(log/SMTP|server/imap)' || true; }

run_mode() {
    mode=$1
    local cli=$2
    local user=${3:-}
    local as=()
    [ -n "$user" ] && as=(--user "$user")

    cleanup
    docker volume create "$name" >/dev/null

    # `init` creates the keychain and vault; the piped CLI commands set the mode.
    printf '%bexit\n' "$cli" | docker run --rm -i "${as[@]}" -v "$name:/root" "$image" init >/dev/null 2>&1 || true

    docker run -d --name "$name" --health-interval=3s "${as[@]}" -v "$name:/root" "$image" >/dev/null

    wait_health healthy 150

    # Let a few more checks run, then make sure they stayed green and quiet.
    sleep 12
    [ "$(health)" = healthy ] || fail "did not stay healthy"
    [ -z "$(probe_errors)" ] || fail "healthcheck makes the bridge log errors"

    if [ -n "$user" ]; then
        local uid
        uid=$(docker exec "$name" ps -o uid= -C proton-bridge,bridge | tr -d ' ' | sort -u || true)
        [ "$uid" = "${user%%:*}" ] || fail "bridge runs as uid '$uid', expected ${user%%:*}"
    fi

    # A dead socat closes a published port while the bridge keeps running.
    docker exec "$name" pkill -f 'TCP-LISTEN:25,'
    wait_health unhealthy 60

    docker stop "$name" >/dev/null
    local code
    code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
    [ "$code" != 137 ] || fail "docker stop ended in SIGKILL"

    echo "PASS [$mode]"
}

# Run only the entrypoint as uid 1000 on a volume prepared by root, and check
# whether the ownership guard lets it through. Accepted means it reached the
# "Starting" line; the bridge is then stopped by the timeout, no health wait.
# Usage: check_guard <label> <accept|reject> <root setup script> [docker run args...]
check_guard() {
    mode=guard-$1
    local want=$2 setup=$3
    shift 3
    local out rc

    cleanup
    docker volume create "$name" >/dev/null
    docker volume create "$name-certs" >/dev/null
    docker run --rm --user 0 --entrypoint bash -v "$name:/root" -v "$name-certs:/certs" "$image" -c "$setup"

    rc=0
    out=$(docker run --rm --user 1000:1000 "$@" -v "$name:/root" --entrypoint timeout "$image" 10 bash /protonmail/entrypoint.sh 2>&1) || rc=$?

    if [ "$want" = reject ]; then
        if [ "$rc" != 1 ] || ! grep -q -- '--entrypoint chown' <<<"$out"; then
            echo "$out"
            fail "guard did not reject (exit $rc)"
        fi
    elif ! grep -q 'Starting Proton Mail Bridge' <<<"$out"; then
        echo "$out"
        fail "guard rejected a valid setup (exit $rc)"
    fi
    echo "PASS [$mode]"
}

# A volume used while the container ran as root.
check_guard root-volume reject 'chown -R 0:0 /root && chmod 700 /root'
# HOME is fine, but bridge state inside it still belongs to root.
check_guard root-state reject 'mkdir -p /root/.config/protonmail && chown -R 0:0 /root/.config'
# Custom TLS certificate on a root-owned read-only mount, readable by uid 1000.
check_guard root-certs accept 'echo cert > /certs/cert.pem && chmod 755 /certs && chmod 644 /certs/cert.pem' -v "$name-certs:/root/certs:ro"
# Kubernetes fsGroup volume: /root owned by root:2000 (2775) plus an ext4 lost+found.
check_guard fsgroup accept 'chown 0:2000 /root && chmod 2775 /root && mkdir -m 700 /root/lost+found' --group-add 2000

run_mode starttls ''
run_mode ssl 'change smtp-security\nyes\nchange imap-security\nyes\n'
run_mode nonroot '' 1000:1000
