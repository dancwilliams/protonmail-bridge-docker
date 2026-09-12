#!/bin/bash
#
# Report the container healthy only if it can actually serve mail.
#
# Checking that a bridge process exists is not enough: socat provides the
# published ports 25/143 and is neither supervised nor restarted, so it can die
# while the bridge keeps running. The container then accepts no connection at
# all but still reports healthy, and nothing restarts it.
#
# Both hops are checked: the socat listeners on 25/143, and the bridge itself on
# 1025/1143 behind them. bash's /dev/tcp is used so the image needs no
# additional package.

set -u

# `docker run ... init` drops the user into the bridge CLI to log in, and that
# path deliberately starts no socat: 25 and 143 are closed by design there, for
# as long as the login and the initial sync take. HEALTHCHECK is an image-level
# property and applies to that container too, so without this the whole
# onboarding shows up as unhealthy.
#
# PID 1 is matched on `init` rather than on `--cli`, because it reads
# "bash /protonmail/entrypoint.sh init" for as long as the GPG key is being
# generated and only becomes "/protonmail/proton-bridge --cli init" once the
# entrypoint execs. `init` is the one token present through both phases, and it
# never appears in the serving path ("--noninteractive").
if grep -qE '(^| )(init|--cli)( |$)' <(tr '\0' ' ' < /proc/1/cmdline); then
    echo "interactive CLI session, nothing to serve yet"
    exit 0
fi

# Probe one port and walk out through the front door: greet, say goodbye, and
# read the reply until the peer hangs up. Anything less makes the bridge log an
# error on every single probe -- dropping the socket outright gives
# "connection reset by peer", and closing before reading the farewell reply
# gives "write: broken pipe". Either would bury real errors in the logs.
#
# Reads are line-based and timeout-bounded: a size-based read would block until
# the peer closes, and both protocols speak in CRLF lines.
#
# The connect is wrapped in a group because a failing `exec` redirection is
# reported by the shell itself, which a redirection on `exec` alone does not
# silence -- the refusal would leak into the health log next to our own message.
probe() {
    local port=$1 farewell=$2

    { exec 3<>"/dev/tcp/127.0.0.1/${port}"; } 2>/dev/null || return 1

    IFS= read -r -t 3 -u 3 _ 2>/dev/null                    # greeting
    printf '%s\r\n' "$farewell" >&3 2>/dev/null             # QUIT / LOGOUT
    while IFS= read -r -t 2 -u 3 _ 2>/dev/null; do :; done  # reply, until EOF

    exec 3<&- 3>&-
    return 0
}

probe 25   "QUIT"      || { echo "SMTP port 25 is not accepting connections";        exit 1; }
probe 143  "a LOGOUT"  || { echo "IMAP port 143 is not accepting connections";       exit 1; }
probe 1025 "QUIT"      || { echo "bridge SMTP (1025) is not accepting connections";  exit 1; }
probe 1143 "a LOGOUT"  || { echo "bridge IMAP (1143) is not accepting connections";  exit 1; }
