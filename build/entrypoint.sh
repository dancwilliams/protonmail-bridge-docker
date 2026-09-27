#!/bin/bash

set -e

# The launcher execs any newer bridge it finds here (downloaded by the
# built-in updater, amd64 only) instead of the image's binaries. Drop it so
# the image version always runs, on every architecture.
rm -rf "$HOME/.local/share/protonmail/bridge-v3/updates"

# Workaround for stale gpg-agent socket causing auth failures on restart
# Cleans up leftover sockets in the GPG home directory
if [ -d /root/.gnupg ]; then
    rm -f /root/.gnupg/S.gpg-agent*
fi

# Preset passphrase into gpg-agent for pass/bridge to decrypt credentials
setup_gpg_passphrase() {
    local conf="$HOME/.gnupg/gpg-agent.conf"
    mkdir -p "$HOME/.gnupg"
    chmod 700 "$HOME/.gnupg"

    local needs_reload=0
    if ! grep -q "allow-preset-passphrase" "$conf" 2>/dev/null; then
        echo "allow-preset-passphrase" >> "$conf"
        needs_reload=1
    fi

    # gpg-preset-passphrase does not auto-start gpg-agent, and listing public
    # keys alone does not reliably spawn it. Launch explicitly.
    gpgconf --launch gpg-agent

    if [ "$needs_reload" = "1" ]; then
        gpg-connect-agent reloadagent /bye >/dev/null
    fi

    local keygrip
    keygrip=$(gpg --list-keys --with-keygrip pass-key 2>/dev/null | grep Keygrip | head -1 | awk '{print $3}')

    if [ -n "$keygrip" ]; then
        /usr/lib/gnupg2/gpg-preset-passphrase -P "$KEYRING_PASSPHRASE" -c "$keygrip"
    fi
}

# Initialize
if [[ $1 == init ]]; then

    # Generate GPG key if not already present
    if ! gpg --list-secret-keys pass-key 2>/dev/null; then
        if [ -n "$KEYRING_PASSPHRASE" ]; then
            passphrase_config=$(printf 'Passphrase: %s\n' "$KEYRING_PASSPHRASE")
        else
            passphrase_config='%no-protection'
        fi
        sed "s/^<PASSPHRASE_CONFIG>\$/${passphrase_config}/" < /protonmail/gpgparams | gpg --batch --generate-key
    fi

    # Initialize pass if not already present
    if [ ! -d "$HOME"/.password-store ]; then
        pass init pass-key
    fi

    # Preset passphrase so bridge CLI can access credentials during login
    if [ -n "$KEYRING_PASSPHRASE" ]; then
        setup_gpg_passphrase
    fi

    # Kill the other instance as only one can be running at a time.
    # This allows users to run entrypoint init inside a running container
    # which is useful in a k8s environment.
    # || true to make sure this would not fail in case there is no running instance.
    pkill -f proton-bridge || true

    # Login. exec so the CLI becomes PID 1 and receives signals directly.
    exec /protonmail/proton-bridge --cli "$@"

else

    # Preset passphrase so bridge can decrypt credentials
    if [ -n "$KEYRING_PASSPHRASE" ]; then
        setup_gpg_passphrase
    fi

    # socat will make the conn appear to come from 127.0.0.1
    # ProtonMail Bridge currently expects that.
    # It also allows us to bind to the real ports :)
    socat TCP-LISTEN:25,fork TCP:127.0.0.1:1025 &
    socat TCP-LISTEN:143,fork TCP:127.0.0.1:1143 &

    # Persist AutoUpdate=false in the vault so the updater stops downloading.
    #
    # This used to be typed into the faketty FIFO of the long-running --cli
    # session. That session is gone (see below), so it is done here instead, in
    # a short-lived --cli run fed on stdin: the CLI quits on EOF -- the very
    # behaviour faketty existed to prevent -- so the pipe closing ends it.
    #
    # Guarded by a marker so it costs one extra bridge startup once in the life
    # of the volume, not one per boot. `if` also shields the pipeline from
    # `set -e`: failing to persist a preference must not stop the container from
    # starting, and an unwritten marker simply retries on the next boot.
    #
    # The password store is a precondition, not a nicety. Started on a volume
    # that has never seen `init`, the bridge finds no keychain, opens no vault
    # and has nowhere to write the setting -- yet the marker would be dropped
    # all the same, so the later `init` would never get its AutoUpdate=false.
    if [ ! -f "$HOME/.autoupdate-disabled" ] && [ -d "$HOME/.password-store" ]; then
        if printf 'updates autoupdates disable\nyes\n' | /protonmail/proton-bridge --cli; then
            touch "$HOME/.autoupdate-disabled"
        fi
    fi

    # Start protonmail.
    #
    # --noninteractive is the upstream-supported way to run the bridge without a
    # frontend, so no terminal has to be faked at all: the faketty FIFO and the
    # process that had to hold it open are both gone.
    #
    # exec matters as much as the flag. Without it bash stays PID 1, and the
    # kernel does not deliver default-action signals to PID 1, so SIGTERM was
    # silently discarded and every `docker stop` ended in SIGKILL after the
    # 10s grace period (exit 137) with the vault never closed cleanly.
    exec /protonmail/proton-bridge --noninteractive "$@"

fi
