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
# Usage: smoke-test.sh <image>

set -euo pipefail

image=$1
name=smoke-$$

cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker volume rm "$name" >/dev/null 2>&1 || true
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

    cleanup
    docker volume create "$name" >/dev/null

    # `init` creates the keychain and vault; the piped CLI commands set the mode.
    printf '%bexit\n' "$cli" | docker run --rm -i -v "$name:/root" "$image" init >/dev/null 2>&1 || true

    docker run -d --name "$name" --health-interval=3s -v "$name:/root" "$image" >/dev/null

    wait_health healthy 150

    # Let a few more checks run, then make sure they stayed green and quiet.
    sleep 12
    [ "$(health)" = healthy ] || fail "did not stay healthy"
    [ -z "$(probe_errors)" ] || fail "healthcheck makes the bridge log errors"

    # A dead socat closes a published port while the bridge keeps running.
    docker exec "$name" pkill -f 'TCP-LISTEN:25,'
    wait_health unhealthy 60

    docker stop "$name" >/dev/null
    local code
    code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
    [ "$code" != 137 ] || fail "docker stop ended in SIGKILL"

    echo "PASS [$mode]"
}

run_mode starttls ''
run_mode ssl 'change smtp-security\nyes\nchange imap-security\nyes\n'
