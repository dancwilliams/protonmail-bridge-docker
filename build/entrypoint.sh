#!/bin/bash

set -e

# Workaround for stale gpg-agent socket causing auth failures on restart
# Cleans up leftover sockets in the GPG home directory
if [ -d /root/.gnupg ]; then
    rm -f /root/.gnupg/S.gpg-agent*
fi

# Preset passphrase into gpg-agent for pass/bridge to decrypt credentials
setup_gpg_passphrase() {
    # Ensure gpg-agent.conf allows preset passphrases
    gpg --list-keys >&/dev/null
    if ! grep -q "allow-preset-passphrase" "$HOME"/.gnupg/gpg-agent.conf 2>/dev/null; then
        echo "allow-preset-passphrase" >> "$HOME"/.gnupg/gpg-agent.conf
    fi

    # Restart gpg-agent with preset support
    gpgconf --kill gpg-agent 2>/dev/null || true
    gpg-agent --homedir "$HOME"/.gnupg --daemon --allow-preset-passphrase 2>/dev/null || true

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
        # Build gpgparams dynamically based on whether a passphrase is set
        local_gpgparams="/tmp/gpgparams"
        cp /protonmail/gpgparams "$local_gpgparams"
        if [ -n "$KEYRING_PASSPHRASE" ]; then
            # Insert passphrase after Key-Length line
            sed -i "/^Key-Length:/a Passphrase: $KEYRING_PASSPHRASE" "$local_gpgparams"
        else
            # No passphrase — prepend %no-protection
            sed -i '1i %no-protection' "$local_gpgparams"
        fi

        gpg --generate-key --batch "$local_gpgparams"
        rm -f "$local_gpgparams"
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

    # Login
    /protonmail/proton-bridge --cli $@

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

    # Start protonmail
    # Fake a terminal, so it does not quit because of EOF...
    rm -f faketty
    mkfifo faketty

    # Keep faketty open indefinitely (more stable than cat pipe over long uptimes)
    sleep infinity > faketty &

    # Start bridge reading from faketty; wait so container exits with bridge's exit code
    /protonmail/proton-bridge --cli $@ < faketty &
    wait $!
    exit $?

fi
