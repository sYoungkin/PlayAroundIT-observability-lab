# Splunk Secret Synchronization

This document covers the `splunk.secret` file — what it is, why it needs to be synchronized, and the exact procedure used in the PlayAroundIT Observability Lab.

---

## What is splunk.secret?

The `splunk.secret` file contains the encryption key Splunk uses to encrypt passwords in configuration files. When Splunk detects a plaintext password in a `.conf` file (such as `pass4SymmKey` in `server.conf`, or LDAP bind passwords in `authentication.conf`), it encrypts it using this key. Encrypted values are prefixed with `$1$`, `$2$`, or `$7$` depending on the encryption method used.

**Location:** `/opt/splunk/etc/auth/splunk.secret`

**Key properties:**
- Exactly 254 characters
- Generated automatically on first Splunk start if not already present
- If the file exists before first start, Splunk uses it as-is and never overwrites it
- If removed or changed after passwords have been encrypted, all encrypted values become unreadable

---

## Why Synchronization is Required

A Splunk cluster will form and function correctly regardless of whether nodes share the same `splunk.secret`. Cluster communication, peer registration, replication, and bundle pushes are not dependent on secret synchronization.

The reason to synchronize `splunk.secret` is:

**Encrypted passwords in configuration files are portable across nodes only if those nodes share the same secret.**

If nodes have different secrets:
- LDAP bind passwords configured on one node cannot be decrypted on another
- Encrypted `pass4SymmKey` values in deployed app configs become unreadable on nodes with a different secret
- Any app containing encrypted credentials becomes non-portable across the environment

Synchronizing the secret before first start ensures that encrypted credentials in configuration files and deployed apps work consistently across all nodes in the same tier.

---

## Secret Distribution Plan for This Lab

Two separate secrets are used — one per tier. Each management node shares the secret of the tier it serves.

| Node | Tier | Secret |
|---|---|---|
| mgmt-1 | Search head tier | Search head secret |
| sh-1 | Search head tier | Search head secret |
| sh-2 | Search head tier | Search head secret |
| mgmt-2 | Indexer tier | Indexer secret |
| idx-1 | Indexer tier | Indexer secret |
| idx-2 | Indexer tier | Indexer secret |

**Why mgmt-1 shares the search head secret:**
The Search Head Deployer (mgmt-1) needs to share the same secret as the search head cluster members so that encrypted passwords in deployed apps (e.g. LDAP bind passwords configured via the UI) can be decrypted by the search heads without requiring cleartext redeployment.

**Why mgmt-2 shares the indexer secret:**
Encrypted passwords in configuration files are portable across nodes only if those nodes share the same secret. Sharing the secret between the Cluster Manager and its peers ensures that any encrypted credentials in configuration bundles are readable across the indexer tier.

---

## Full Procedure

### Search Head Tier (mgmt-1 → sh-1, sh-2)

**Step 1 — Generate and write the secret directly on mgmt-1:**

```bash
cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 254 | \
  sudo tee /opt/splunk/etc/auth/splunk.secret > /dev/null
sudo chown splunk:splunk /opt/splunk/etc/auth/splunk.secret
sudo chmod 400 /opt/splunk/etc/auth/splunk.secret
```

**Step 2 — SCP the secret directly from mgmt-1 to each search head:**

```bash
# Run from mgmt-1
scp /opt/splunk/etc/auth/splunk.secret vagrant@<sh1_ip>:/tmp/splunk.secret
scp /opt/splunk/etc/auth/splunk.secret vagrant@<sh2_ip>:/tmp/splunk.secret
```

**Step 3 — On sh-1 and sh-2, move the file into place:**

```bash
sudo mv /tmp/splunk.secret /opt/splunk/etc/auth/splunk.secret
sudo chown splunk:splunk /opt/splunk/etc/auth/splunk.secret
sudo chmod 400 /opt/splunk/etc/auth/splunk.secret
```

---

### Indexer Tier (mgmt-2 → idx-1, idx-2)

**Step 1 — Generate and write the secret directly on mgmt-2:**

```bash
cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 254 | \
  sudo tee /opt/splunk/etc/auth/splunk.secret > /dev/null
sudo chown splunk:splunk /opt/splunk/etc/auth/splunk.secret
sudo chmod 400 /opt/splunk/etc/auth/splunk.secret
```

**Step 2 — SCP the secret directly from mgmt-2 to each indexer:**

```bash
# Run from mgmt-2
scp /opt/splunk/etc/auth/splunk.secret vagrant@<idx1_ip>:/tmp/splunk.secret
scp /opt/splunk/etc/auth/splunk.secret vagrant@<idx2_ip>:/tmp/splunk.secret
```

**Step 3 — On idx-1 and idx-2, move the file into place:**

```bash
sudo mv /tmp/splunk.secret /opt/splunk/etc/auth/splunk.secret
sudo chown splunk:splunk /opt/splunk/etc/auth/splunk.secret
sudo chmod 400 /opt/splunk/etc/auth/splunk.secret
```

---

## Verification

After writing the secrets, verify consistency within each tier by comparing checksums. All nodes in the same tier must produce identical output.

```bash
sudo md5sum /opt/splunk/etc/auth/splunk.secret
```

Run on every node in each tier:
- All search head tier nodes (mgmt-1, sh-1, sh-2) must match
- All indexer tier nodes (mgmt-2, idx-1, idx-2) must match
- The two tier hashes must be different from each other

Also verify correct permissions and ownership:

```bash
ls -la /opt/splunk/etc/auth/splunk.secret
```

Expected output:
```
-r-------- 1 splunk splunk 254 ... /opt/splunk/etc/auth/splunk.secret
```

And confirm exactly 254 characters:

```bash
wc -c /opt/splunk/etc/auth/splunk.secret
```

Expected output: `254 /opt/splunk/etc/auth/splunk.secret`

---

## Finding Encrypted Values in Config Files

After Splunk has started and encrypted plaintext passwords, you can find all encrypted values across the configuration with:

```bash
find /opt/splunk/etc -type f -name "*.conf" \
  -exec grep -iH "\$1\$\|\$2\$\|\$7\$" {} \;
```

This is useful for auditing which config files contain encrypted passwords before changing or rotating the `splunk.secret`.

---

## Notes

- **Never commit `splunk.secret` to the repo** — it is an encryption key and must be treated as a secret
- **Do not rotate the secret after Splunk has started** without also re-encrypting all encrypted values in all config files — this will break the environment if done incorrectly
- The SHC captain does synchronize some configuration across search head cluster members, but relying on it for initial secret synchronization is not recommended — set the secret manually before first start
- If you need to rebuild the environment, generate fresh secrets — do not reuse old ones
- `tee` with `> /dev/null` suppresses output to the terminal so the secret is never visible in terminal history