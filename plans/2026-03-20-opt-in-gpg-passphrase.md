# Opt-in GPG Keyring Passphrase Support

## Overview

Add optional GPG key passphrase protection via a `KEYRING_PASSPHRASE` environment variable (issue #30). When set, the GPG private key backing `pass` is encrypted with the provided passphrase, so volume theft alone doesn't expose credentials. When unset, behavior is identical to today.

## Current State

- `build/gpgparams` contains `%no-protection` — GPG key is generated without a passphrase
- `build/entrypoint.sh` has two paths: `init` (generates GPG key + pass store, launches CLI for login) and normal run (starts socat + bridge)
- No environment variables are used anywhere in the container
- `gpg-preset-passphrase` is available at `/usr/lib/gnupg2/gpg-preset-passphrase` via the `pass` → `gnupg` → `gnupg-utils` dependency chain — no new packages needed
- `set -ex` in entrypoint would log the passphrase to stdout via `-x`

## Desired End State

- Users who set `KEYRING_PASSPHRASE` get a passphrase-protected GPG key
- Users who don't set it see zero behavior change
- The container handles all GPG agent/passphrase plumbing internally — the user never interacts with GPG directly
- Existing volumes with unprotected keys continue working (users must re-init to adopt passphrase protection)

## What We're NOT Doing

- Auto-generating passphrases (user must provide externally)
- Migrating existing unprotected keys in-place (requires re-init)
- Making passphrase mandatory (opt-in only)
- Changing the default behavior in any way

## Implementation Approach

The changes are concentrated in `entrypoint.sh` with a minor update to `gpgparams`. The entrypoint conditionally branches based on whether `KEYRING_PASSPHRASE` is set, adding GPG agent startup and passphrase preset only when needed.

---

## Phase 1: Core Changes (entrypoint.sh + gpgparams)

### Overview
Modify the entrypoint to conditionally handle passphrase-protected GPG keys, and update gpgparams.

### Changes Required:

#### 1. `build/gpgparams` — Remove `%no-protection`, bump key size

**Current:**
```
%no-protection
%echo Generating a basic OpenPGP key
Key-Type: RSA
Key-Length: 2048
Name-Real: pass-key
Expire-Date: 0
%commit
%echo done
```

**New:**
```
%echo Generating a basic OpenPGP key
Key-Type: RSA
Key-Length: 4096
Name-Real: pass-key
Expire-Date: 0
%commit
%echo done
```

- `%no-protection` is removed from the static file — it will be handled conditionally at runtime
- Key size bumped from 2048 to 4096 (stronger key, negligible performance impact since it's generated once)

#### 2. `build/entrypoint.sh` — Add passphrase handling

**Key changes:**

1. **Replace `set -ex` with `set -e`** — removes trace logging that would expose the passphrase. Debug logging is a development concern, not appropriate for a production entrypoint.

2. **Add a helper function to preset the passphrase into gpg-agent:**
```bash
setup_gpg_passphrase() {
    # Start gpg-agent with preset passphrase support
    gpg-agent --homedir "$HOME"/.gnupg --daemon --allow-preset-passphrase 2>/dev/null || true

    # Get the keygrip of the private key
    local keygrip
    keygrip=$(gpg --list-keys --with-keygrip pass-key 2>/dev/null | grep Keygrip | head -1 | awk '{print $3}')

    if [ -n "$keygrip" ]; then
        /usr/lib/gnupg2/gpg-preset-passphrase -P "$KEYRING_PASSPHRASE" -c "$keygrip"
    fi
}
```

3. **Modify the `init` branch** to conditionally generate the key with or without passphrase:
```bash
if [[ $1 == init ]]; then
    # Skip GPG/pass init if already done (idempotent)
    if [ ! -d "$HOME"/.gnupg/private-keys-v1.d ] || [ -z "$(ls -A "$HOME"/.gnupg/private-keys-v1.d/ 2>/dev/null)" ]; then
        if [ -n "$KEYRING_PASSPHRASE" ]; then
            # Generate key with passphrase protection
            gpg --generate-key --passphrase "$KEYRING_PASSPHRASE" --pinentry-mode loopback --batch /protonmail/gpgparams
        else
            # Generate key without passphrase (legacy behavior)
            gpg --generate-key --passphrase "" --pinentry-mode loopback --batch /protonmail/gpgparams
        fi
    fi

    if [ ! -d "$HOME"/.password-store ]; then
        pass init pass-key
    fi

    # Preset passphrase if set, so bridge CLI can access credentials during login
    if [ -n "$KEYRING_PASSPHRASE" ]; then
        setup_gpg_passphrase
    fi

    # ... rest of init (pkill, launch CLI)
fi
```

4. **Modify the normal run branch** to preset passphrase before starting bridge:
```bash
else
    # If passphrase is set, preset it in gpg-agent so bridge can decrypt
    if [ -n "$KEYRING_PASSPHRASE" ]; then
        setup_gpg_passphrase
    fi

    # ... rest of normal run (socat, bridge start)
fi
```

**Full revised entrypoint.sh:**

```bash
#!/bin/bash

set -e

# Workaround for stale gpg-agent socket causing auth failures on restart
# Cleans up leftover sockets in the GPG home directory
if [ -d /root/.gnupg ]; then
    rm -f /root/.gnupg/S.gpg-agent*
fi

# Preset passphrase into gpg-agent for pass/bridge to decrypt credentials
setup_gpg_passphrase() {
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
    if [ ! -d "$HOME"/.gnupg/private-keys-v1.d ] || [ -z "$(ls -A "$HOME"/.gnupg/private-keys-v1.d/ 2>/dev/null)" ]; then
        if [ -n "$KEYRING_PASSPHRASE" ]; then
            gpg --generate-key --passphrase "$KEYRING_PASSPHRASE" --pinentry-mode loopback --batch /protonmail/gpgparams
        else
            gpg --generate-key --passphrase "" --pinentry-mode loopback --batch /protonmail/gpgparams
        fi
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
    pkill protonmail-bridge || true

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
```

### How it works end-to-end:

1. **User runs `init` with `-e KEYRING_PASSPHRASE=mysecret`**: GPG key is generated with passphrase protection. `pass` store is initialized. Passphrase is preset in `gpg-agent` so the bridge CLI can decrypt during `login`.

2. **User runs normally with `-e KEYRING_PASSPHRASE=mysecret`**: Stale sockets cleaned up. `gpg-agent` started with `--allow-preset-passphrase`. Passphrase preset via `gpg-preset-passphrase`. Bridge starts and can decrypt `pass` entries transparently.

3. **User runs without `KEYRING_PASSPHRASE`**: Identical to current behavior. GPG key has no passphrase. No `gpg-agent` preset needed.

### Success Criteria:

#### Automated Verification:
- [ ] Docker image builds successfully: `docker build -t protonmail-bridge-test -f build/Dockerfile build/`
- [ ] Container starts without `KEYRING_PASSPHRASE` (backward compat): `docker run --rm dancwilliams/protonmail-bridge echo "ok"`
- [ ] `shellcheck build/entrypoint.sh` passes (no obvious script errors)

#### Manual Verification:
- [ ] Init with `KEYRING_PASSPHRASE` set: GPG key is passphrase-protected (verify with `gpg --list-keys`)
- [ ] Init without `KEYRING_PASSPHRASE`: GPG key has no passphrase (current behavior preserved)
- [ ] Normal run with `KEYRING_PASSPHRASE`: bridge starts and can access credentials
- [ ] Normal run without `KEYRING_PASSPHRASE`: bridge starts normally (no regression)
- [ ] Re-running init on existing volume skips GPG/pass initialization (idempotent)

**Implementation Note**: After completing this phase and all automated verification passes, pause for manual confirmation before proceeding.

---

## Phase 2: Documentation

### Overview
Update README and docker-compose.yml to document the new feature.

### Changes Required:

#### 1. `docker-compose.yml` — Add commented environment example

Add a commented `environment` block showing `KEYRING_PASSPHRASE`:
```yaml
services:
  protonmail-bridge:
    image: dancwilliams/protonmail-bridge:latest
    ports:
      - "1025:25/tcp"
      - "1143:143/tcp"
    restart: unless-stopped
    volumes:
      - protonmail:/root
    # Optional: set a passphrase to encrypt the GPG keyring
    # environment:
    #   - KEYRING_PASSPHRASE=your-passphrase-here
```

#### 2. `README.md` — Document KEYRING_PASSPHRASE

Add a new subsection under the existing **Security** section:

```markdown
### Credential storage

By default, the container stores Protonmail credentials in a `pass` password store backed
by a GPG key without a passphrase. This means if the Docker volume is stolen, the
credentials can be recovered.

To encrypt the GPG key with a passphrase, set the `KEYRING_PASSPHRASE` environment variable:

**docker run:**
```
docker run -d --name=protonmail-bridge \
    -v protonmail:/root \
    -p 1025:25/tcp \
    -p 1143:143/tcp \
    -e KEYRING_PASSPHRASE=your-passphrase-here \
    --restart=unless-stopped \
    dancwilliams/protonmail-bridge:latest
```

**docker compose:**
```yaml
environment:
  - KEYRING_PASSPHRASE=your-passphrase-here
```

> **Note:** Adopting this on an existing setup requires re-running `init` with the
> environment variable set. This will regenerate the GPG key and you will need to
> re-authenticate with Protonmail.
```

### Success Criteria:

#### Automated Verification:
- [ ] README renders correctly (no broken markdown)

#### Manual Verification:
- [ ] Documentation is clear and complete
- [ ] docker-compose.yml example works with passphrase set

---

## Migration Notes

- **Existing users (no passphrase):** No action required. Container continues working as before.
- **Existing users (want passphrase):** Must re-run `init` with `KEYRING_PASSPHRASE` set, which regenerates the GPG key and requires re-authenticating with Protonmail via `login`.
- **New users:** Can optionally set `KEYRING_PASSPHRASE` on their first `init`.

## Risk Assessment

- **Low risk for existing users:** No behavior change when `KEYRING_PASSPHRASE` is unset
- **`set -x` removal:** Removes debug trace output, which could make debugging harder — but it's necessary to avoid leaking secrets, and users can add it back temporarily if needed
- **`gpg-preset-passphrase` availability:** Verified present at `/usr/lib/gnupg2/gpg-preset-passphrase` via the `pass` dependency chain on `debian:bookworm-slim` — no extra packages needed
- **Key size bump (2048→4096):** Only affects new `init` runs. Slightly slower key generation (one-time cost). No impact on existing volumes.

## Testing Guide

Testing the entrypoint requires `--entrypoint bash` to override the container's default entrypoint,
otherwise arguments are passed to `entrypoint.sh` and the bridge takes over stdout.

### Key gotchas discovered during development

1. **GPG batch file must start with `Key-Type`** — the `Passphrase:` directive cannot appear before
   `Key-Type` or GPG rejects the file with "parameter block does not start with Key-Type".

2. **`--passphrase` CLI flag does NOT set the key passphrase during `--generate-key`** — it's for
   decrypting existing keys. You must use the `Passphrase:` directive inside the batch file.

3. **`gpg-agent` caches passphrases** — when verifying that a key is passphrase-protected, you must
   `gpgconf --kill gpg-agent` before each test, otherwise the agent serves the cached passphrase
   and even wrong/empty passphrases appear to succeed.

4. **`gpg-preset-passphrase` requires `allow-preset-passphrase` in `gpg-agent.conf`** — passing
   `--allow-preset-passphrase` to `gpg-agent --daemon` alone is not sufficient because gpg-agent
   may auto-start during GPG operations before you launch it manually. Write the config file before
   any GPG operations.

5. **`pkill protonmail-bridge` silently fails** — the process name is `proton-bridge` (15 char limit),
   and `pkill` without `-f` truncates the pattern. Use `pkill -f proton-bridge` to match the full
   command line.

### Test 1: Init without passphrase (backward compatibility)

```bash
docker run --rm --entrypoint bash protonmail-bridge-test -c '
echo "=== Test: Init WITHOUT passphrase ==="
bash /protonmail/entrypoint.sh init 2>&1 &
PID=$!
sleep 15
echo "--- GPG keys ---"
gpg --list-keys pass-key 2>/dev/null
echo "--- Pass store exists ---"
ls ~/.password-store/.gpg-id 2>/dev/null && echo "PASS: pass store initialized" || echo "FAIL"
echo "--- Verify key has no passphrase ---"
gpgconf --kill gpg-agent
echo "test" | gpg --pinentry-mode loopback --passphrase "" --sign --local-user pass-key \
  > /dev/null 2>&1 && echo "PASS: no passphrase needed" || echo "FAIL"
kill $PID 2>/dev/null
'
```

### Test 2: Init with passphrase

```bash
docker run --rm --entrypoint bash -e KEYRING_PASSPHRASE=test-secret-123 protonmail-bridge-test -c '
echo "=== Test: Init WITH passphrase ==="
bash /protonmail/entrypoint.sh init 2>&1 &
PID=$!
sleep 15
echo "--- GPG keys ---"
gpg --list-keys pass-key 2>/dev/null
echo "--- Pass store exists ---"
ls ~/.password-store/.gpg-id 2>/dev/null && echo "PASS: pass store initialized" || echo "FAIL"
echo "--- Verify key IS passphrase-protected ---"
gpgconf --kill gpg-agent
echo "test" | gpg --pinentry-mode loopback --passphrase "test-secret-123" --sign --local-user pass-key \
  > /dev/null 2>&1 && echo "PASS: correct passphrase works" || echo "FAIL"
gpgconf --kill gpg-agent
echo "test" | gpg --pinentry-mode loopback --passphrase "wrong" --sign --local-user pass-key \
  > /dev/null 2>&1 && echo "FAIL: wrong passphrase accepted" || echo "PASS: wrong passphrase rejected"
echo "--- Verify preset passphrase enables pass ---"
gpgconf --kill gpg-agent
gpg-agent --homedir /root/.gnupg --daemon --allow-preset-passphrase 2>/dev/null || true
keygrip=$(gpg --list-keys --with-keygrip pass-key 2>/dev/null | grep Keygrip | head -1 | awk "{print \$3}")
/usr/lib/gnupg2/gpg-preset-passphrase -P "test-secret-123" -c "$keygrip" 2>&1 \
  && echo "PASS: preset succeeded" || echo "FAIL: preset failed"
echo "secret-data" | pass insert -e verify-entry 2>&1
pass show verify-entry 2>&1 && echo "PASS: pass works with preset" || echo "FAIL"
kill $PID 2>/dev/null
'
```

### Expected results

| Test | Expected |
|------|----------|
| No-passphrase init: GPG key generated | RSA 4096 key for `pass-key` |
| No-passphrase init: pass store created | `.gpg-id` exists |
| No-passphrase: empty passphrase signs | PASS (key is unprotected) |
| Passphrase init: correct passphrase signs | PASS |
| Passphrase init: wrong passphrase signs | FAIL (key is protected) |
| Passphrase: gpg-preset-passphrase caching | PASS |
| Passphrase: pass insert/retrieve via preset | PASS |
| Bridge CLI launches (both modes) | Shows interactive shell banner |

## References

- Issue: https://github.com/dancwilliams/protonmail-bridge-docker/issues/30
- Upstream PR: https://github.com/shenxn/protonmail-bridge-docker/pull/132
- `build/entrypoint.sh` — main entrypoint script
- `build/gpgparams` — GPG batch parameters
- `build/Dockerfile` — container build definition
