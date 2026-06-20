# Splunk Add-on for Unix and Linux — Deployment & auditd Data Onboarding

This document covers the deployment of the Splunk Add-on for Unix and Linux (`Splunk_TA_nix`) across the lab environment and the configuration of the auditd scripted input on the Universal Forwarder to onboard audit log data into the `linux_audit` index.

---

## Overview

The Splunk Add-on for Unix and Linux is the standard TA for Linux data collection in Splunk environments. It is required by the Splunk Threat Research Team and Splunk Enterprise Security use cases for Linux audit data. It provides:

- Source type definitions and field extractions for Linux data sources
- CIM-compliant field mappings
- Scripted inputs for auditd, system metrics, and other Linux data sources
- The `auditd` source type which decodes hex-encoded `proctitle` values via `ausearch -i`

---

## Architecture — Three Deployments

The TA is deployed in three places with different configurations:

| Destination | Node | Inputs | Purpose |
|---|---|---|---|
| `manager-apps` | mgmt-2 | Disabled | Index-time field extractions on indexers |
| `shcluster/apps` | mgmt-1 | Disabled | Search-time field extractions on search heads |
| `deployment-apps` | mgmt-1 | Enabled (auditd only) | Data collection on Universal Forwarder |

> **Important:** Inputs must be disabled on the indexer and search head deployments. Only the UF deployment has inputs enabled.

---

## Step 1 — Unpack the TA

The TA is downloaded as a `.tgz` tarball from Splunkbase. Unpack it on each management node before copying to the target directories.

```bash
cd /tmp
sudo tar -xzf splunk-add-on-for-unix-and-linux_*.tgz

# Confirm extracted folder name
ls /tmp | grep -i nix
```

The extracted folder name is `Splunk_TA_nix`.

---

## Step 2 — Deploy to Indexer Cluster (no inputs)

```bash
# On mgmt-2
sudo cp -r /tmp/Splunk_TA_nix /opt/splunk/etc/manager-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/manager-apps/Splunk_TA_nix

sudo -u splunk /opt/splunk/bin/splunk validate cluster-bundle
sudo -u splunk /opt/splunk/bin/splunk apply cluster-bundle --answer-yes
```

---

## Step 3 — Deploy to Search Head Cluster (no inputs)

```bash
# On mgmt-1
sudo cp -r /tmp/Splunk_TA_nix /opt/splunk/etc/shcluster/apps/
sudo chown -R splunk:splunk /opt/splunk/etc/shcluster/apps/Splunk_TA_nix

sudo -u splunk /opt/splunk/bin/splunk apply shcluster-bundle \
  -target https://192.168.248.207:8089 \
  --answer-yes
```

---

## Step 4 — Configure UF Deployment (inputs enabled)

The deployment-apps version of the TA needs a `local/inputs.conf` that enables the auditd scripted input and sets the correct index.

### Copy TA to deployment-apps on mgmt-1

```bash
sudo cp -r /tmp/Splunk_TA_nix /opt/splunk/etc/deployment-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/deployment-apps/Splunk_TA_nix
```

### Create local/inputs.conf

```bash
sudo mkdir -p /opt/splunk/etc/deployment-apps/Splunk_TA_nix/local
sudo vi /opt/splunk/etc/deployment-apps/Splunk_TA_nix/local/inputs.conf
```

`local/inputs.conf`:
```ini
[script://./bin/rlog.sh]
sourcetype = auditd
source = auditd
index = linux_audit
interval = 60
disabled = 0
```

**Notes:**
- `rlog.sh` runs `ausearch -i` which interprets auditd events and decodes hex-encoded `proctitle` values
- The decoded `proctitle` contains the full command line that was executed — required for Splunk ES and Threat Research use cases
- `index = linux_audit` routes data to the dedicated audit index
- `disabled = 0` overrides the default `disabled = 1` in `default/inputs.conf`
- Only the settings being overridden need to be in `local/inputs.conf` — everything else inherits from `default/`

### Set permissions on sensitive files

```bash
sudo chmod 600 /opt/splunk/etc/deployment-apps/Splunk_TA_nix/local/inputs.conf
sudo chown splunk:splunk /opt/splunk/etc/deployment-apps/Splunk_TA_nix/local/inputs.conf
```

### Add to server class and reload

Add `Splunk_TA_nix` to the `pait_linux_universal_forwarders` server class in the Agent Management UI, then reload:

```bash
sudo -u splunk /opt/splunk/bin/splunk reload deploy-server
```

The UF will pick up the TA on the next phone home cycle (60 seconds).

---

## Step 5 — Prerequisites on the Universal Forwarder

The `splunk` user must be a member of the `audit_readers` group and auditd must be configured to allow that group to read logs. This is handled automatically by `splunk_uf_install.sh` during provisioning.

Verify on uf-1:

```bash
# Confirm splunk user is in audit_readers group
groups splunk

# Confirm log_group is set in auditd.conf
grep log_group /etc/audit/auditd.conf

# Confirm splunk user can run ausearch
sudo -u splunk ausearch -i -m all --start recent 2>&1 | head -10
```

Expected:
- `audit_readers` appears in `groups splunk` output
- `log_group = audit_readers` in auditd.conf
- `ausearch` returns audit events without permission errors

---

## Verification

### Confirm data is arriving

```splunk
index=linux_audit | head 20
```

### Confirm source type is correct

```splunk
index=linux_audit | stats count by sourcetype
```

Expected: `sourcetype=auditd` with a count greater than zero.

### Confirm host is correct

```splunk
index=linux_audit | stats count by host
```

Expected: `host=uf-1`.

### Confirm proctitle is decoded

```splunk
index=linux_audit sourcetype=auditd proctitle=*
| table _time proctitle
| head 20
```

The `proctitle` field should contain readable command line strings, not hex-encoded values. This confirms `ausearch -i` interpretation is working correctly.

### Confirm volume is receiving data

From the indexer cluster UI on mgmt-2 navigate to **Settings → Indexes → linux_audit**. The hot bucket count should be greater than zero and raw data size should be increasing.

Or via CLI on either indexer:

```bash
ls /opt/splunkdata/hot/linux_audit/
```

Hot buckets for the `linux_audit` index should be present.

---

## Verifying Source Types in Search Head Cluster

The **Settings → Source Types** menu option may not be visible in the search head cluster UI in Splunk 10.4. This is expected behavior — source types in a SHC are managed via the deployer, not via the local UI on individual members.

Use the REST API from the search bar instead:

**List all active source types:**
```splunk
| rest splunk_server=local /services/saved/sourcetypes
| table title eai:acl.app disabled
```

**Filter for Splunk_TA_nix source types only:**
```splunk
| rest splunk_server=local /services/saved/sourcetypes
| search eai:acl.app="Splunk_TA_nix"
| table title eai:acl.app disabled
```

> **Note:** Use `splunk_server=local` to force the REST call to run on the local search head rather than federating across the cluster. The endpoint `/services/saved/sourcetypes` is the correct one for this query in 10.4.

---

## About the auditd Scripted Input

The `rlog.sh` script in `Splunk_TA_nix` runs:

```bash
ausearch -i -m all
```

The `-i` flag tells `ausearch` to interpret the raw audit records — specifically:
- Hex-encoded values are decoded to human-readable strings
- The `proctitle` field (which contains the full executed command line in hex) is decoded to plaintext
- UID and GID values are resolved to usernames and group names

This interpretation is critical for Splunk Enterprise Security use cases. The Splunk Threat Research Team detection content filters on the decoded `proctitle` field to identify malicious command execution patterns. If raw `linux_audit` source type data is used instead of the interpreted `auditd` source type, the ES detections will not work correctly.

**Source type comparison:**

| Source Type | Input Method | proctitle | ES Compatible |
|---|---|---|---|
| `auditd` | `rlog.sh` scripted input (`ausearch -i`) | Decoded — human readable | Yes |
| `linux_audit` | File monitor (`/var/log/audit/audit.log`) | Hex encoded | No |

---

## Notes

- The TA version deployed to `deployment-apps` must have `local/inputs.conf` with only the auditd input enabled — do not enable all inputs as this would generate significant unwanted data volume
- The `rlog.sh` script requires the `splunk` user to have read access to audit logs — handled via the `audit_readers` group configured during UF provisioning
- Additional inputs from `Splunk_TA_nix` (CPU, memory, network, disk metrics) can be enabled later as needed by adding entries to `local/inputs.conf`
- When upgrading the TA always preserve the `local/inputs.conf` — it will not be overwritten by a TA upgrade but confirm after upgrading
EOF