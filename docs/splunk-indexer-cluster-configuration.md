# Splunk Indexer Cluster Configuration

This document covers the complete configuration of the Splunk 10.4 indexer cluster in the PlayAroundIT Observability Lab, including the Cluster Manager, indexer peers, license manager, and index storage configuration.

---

## Architecture

| Node | Role | IP |
|---|---|---|
| mgmt-2 | Cluster Manager, License Manager | 192.168.248.204 |
| idx-1 | Indexer Peer | 192.168.248.x |
| idx-2 | Indexer Peer | 192.168.248.x |

**Cluster settings:**
- Replication factor: 2
- Search factor: 2
- Single-site cluster
- Cluster label: `playaroundit`

---

## Prerequisites

Before starting any Splunk instance the following must be in place:

1. Splunk 10.4 installed on all nodes via `splunk_install.sh`
2. `splunk.secret` synchronized across the indexer tier — see `docs/splunk-secret-synchronization.md`
3. Splunk data directories created on idx-1 and idx-2

---

## Step 1 — Create Splunk Data Directories on Indexers

Run on both idx-1 and idx-2:

```bash
sudo mkdir -p /opt/splunkdata/{hot,cold,thawed}
sudo chown -R splunk:splunk /opt/splunkdata
sudo chmod -R 755 /opt/splunkdata
```

Verify:
```bash
ls -la /opt/splunkdata/
```

---

## Step 2 — Build pait_cluster_manager_base

**Destination:** mgmt-2 `/opt/splunk/etc/apps`

App structure:
```
pait_cluster_manager_base/
    default/
        server.conf
    metadata/
        default.meta
        local.meta
```

`default/server.conf`:
```ini
[clustering]
mode = manager
replication_factor = 2
search_factor = 2
pass4SymmKey = <indexer_cluster_secret>
cluster_label = playaroundit
multisite = false
```

`metadata/default.meta`:
```
[]
access = read : [ * ], write : [ admin ]
```

`metadata/local.meta`:
```
# local.meta
```

**Deploy to mgmt-2:**
```bash
# From Windows host
vagrant scp ./splunk/apps/pait_cluster_manager_base mgmt-2:/tmp/

# On mgmt-2
sudo cp -r /tmp/pait_cluster_manager_base /opt/splunk/etc/apps/
sudo chown -R splunk:splunk /opt/splunk/etc/apps/pait_cluster_manager_base
```

**Start Splunk on mgmt-2:**
```bash
sudo systemctl start Splunkd
```

**Verify in UI:** Navigate to `http://<mgmt2_ip>:8000` → Settings → Indexer Clustering. mgmt-2 should be listed as the Manager node.

---

## Step 3 — Build pait_cluster_indexer_base

This app bootstraps the indexer peers to the cluster. It is first deployed directly to each indexer's `etc/apps` to establish initial cluster registration, then moved to the Cluster Manager's `manager-apps` for centralized management.

**App structure:**
```
pait_cluster_indexer_base/
    default/
        server.conf
        inputs.conf
        indexes.conf
        web.conf
    metadata/
        default.meta
        local.meta
```

`default/server.conf`:
```ini
[clustering]
mode = peer
manager_uri = https://192.168.248.204:8089
pass4SymmKey = <indexer_cluster_secret>
multisite = false

[replication_port://9100]
disabled = false

[license]
manager_uri = https://192.168.248.204:8089
```

`default/inputs.conf`:
```ini
# BASE SETTINGS
[splunktcp://9997]
disabled = false
```

`default/indexes.conf`:
```ini
[volume:hot_tier]
path = /opt/splunkdata/hot
maxVolumeDataSizeMB = 10000

[volume:cold_tier]
path = /opt/splunkdata/cold
maxVolumeDataSizeMB = 20000

[default]
repFactor = auto
tsidxWritingLevel = 4
homePath   = volume:hot_tier/$_index_name/db
coldPath   = volume:cold_tier/$_index_name/colddb
thawedPath = /opt/splunkdata/thawed/$_index_name/thaweddb
```

`default/web.conf`:
```ini
[settings]
startwebserver = 0
```

**Notes on indexes.conf:**
- Volumes abstract storage tiers — `hot_tier` and `cold_tier` point to separate directories, mirroring how production would use separate physical storage devices
- `$_index_name` is a Splunk macro that automatically creates per-index subdirectories
- `tsidxWritingLevel = 4` enables the latest TSIDX format for improved search performance
- `journalCompression` defaults to `zstd` in 10.4 and does not need to be specified explicitly
- `thawedPath` uses a direct path rather than a volume since thawed data is rarely accessed and does not require volume-based capacity management

---

## Step 4 — Bootstrap Indexer Peers

### Initial bootstrap — deploy directly to each indexer

```bash
# From Windows host — copy to both indexers
vagrant scp ./splunk/apps/pait_cluster_indexer_base idx-1:/tmp/
vagrant scp ./splunk/apps/pait_cluster_indexer_base idx-2:/tmp/
```

On each indexer:
```bash
sudo cp -r /tmp/pait_cluster_indexer_base /opt/splunk/etc/apps/
sudo chown -R splunk:splunk /opt/splunk/etc/apps/pait_cluster_indexer_base

# Add pass4SymmKey in cleartext — Splunk will encrypt on first start
# Edit /opt/splunk/etc/apps/pait_cluster_indexer_base/default/server.conf
# Replace <indexer_cluster_secret> with the actual key

sudo systemctl start Splunkd
```

**Verify peers registered:** In the Cluster Manager UI both indexers should appear as peers with status `Up`.

---

## Step 5 — Move to Manager-Apps for Centralized Management

Once peers are registered with the Cluster Manager, move the indexer base app to `manager-apps` so all future configuration changes are managed centrally via the bundle push mechanism.

**On mgmt-2:**
```bash
# Copy app to manager-apps
sudo cp -r /tmp/pait_cluster_indexer_base /opt/splunk/etc/manager-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/manager-apps/pait_cluster_indexer_base

# Add pass4SymmKey — Splunk will encrypt it when bundle is pushed
# Edit /opt/splunk/etc/manager-apps/pait_cluster_indexer_base/default/server.conf
```

**Validate and push the configuration bundle:**
```bash
sudo -u splunk /opt/splunk/bin/splunk validate cluster-bundle
sudo -u splunk /opt/splunk/bin/splunk apply cluster-bundle
```

**Remove the bootstrap app from each indexer:**
```bash
# On idx-1 and idx-2
sudo rm -rf /opt/splunk/etc/apps/pait_cluster_indexer_base
sudo systemctl restart Splunkd
```

After restart the indexers pull the configuration from the CM bundle. Verify peers are still healthy in the Cluster Manager UI.

---

## Step 6 — Verify License Manager

The `[license]` stanza in `server.conf` points both indexers to mgmt-2 as the License Manager. Verify from the CLI:

**On mgmt-2 — list license peers:**
```bash
sudo -u splunk /opt/splunk/bin/splunk list licenser-slaves
```

Both indexers should be listed.

**On each indexer — confirm license manager URI:**
```bash
sudo -u splunk /opt/splunk/bin/splunk list licenser-localslave
```

**In the UI:** Settings → Licensing → click "Show all license details" to see connected peers.

> **Note:** In 10.4 the UI uses updated terminology — look for "license peers" rather than "license slaves". The CLI command `list licenser-slaves` still works for backwards compatibility.

---

## Verification Checklist

```bash
# Check cluster status from mgmt-2
sudo -u splunk /opt/splunk/bin/splunk show cluster-status

# Check peer list
sudo -u splunk /opt/splunk/bin/splunk show cluster-peers

# Verify bundle was applied to peers
sudo -u splunk /opt/splunk/bin/splunk show cluster-bundle-status

# Check encrypted pass4SymmKey is consistent across nodes
sudo -u splunk /opt/splunk/bin/splunk show-decrypted \
  --value '$7$<encrypted_value_from_server.conf>'
```

**Expected cluster status:**
- Manager node: `Active`
- Both peers: `Up`
- Replication factor met: `Yes`
- Search factor met: `Yes`

---

## Troubleshooting

**Peers not registering after start:**
Check `pass4SymmKey` matches between the CM and the indexers. Check `manager_uri` is correct and port 8089 is reachable.

```bash
sudo tail -100 /opt/splunk/var/log/splunk/splunkd.log | grep -i "cluster\|peer\|manager"
```

**Bundle push fails:**
Validate the bundle first — validation errors will show the specific config problem:
```bash
sudo -u splunk /opt/splunk/bin/splunk validate cluster-bundle
```

**Peers go down after bundle push:**
Check that the app deployed via bundle does not conflict with any app already in `etc/apps` on the indexers. Remove any duplicate apps from `etc/apps` on the indexers and restart.

**Encrypted pass4SymmKey looks different across nodes:**
This is expected and correct. Splunk uses non-deterministic encryption — the same plaintext encrypted multiple times produces different ciphertext. Use `show-decrypted` to verify all nodes decrypt to the same plaintext value.

**License peers not showing in UI:**
The UI may take a few minutes to reflect connected peers. Use `splunk list licenser-slaves` on the CLI for immediate verification.

---

## Notes

- Apps in `manager-apps` are never run locally on the Cluster Manager — they are only distributed to peers via the configuration bundle
- Always validate the bundle before applying — `validate cluster-bundle` catches errors before they reach the peers
- Do not use `splunk restart` on peer nodes once replication has begun — use `systemctl restart Splunkd` or `splunk offline` followed by `splunk start` for safe restarts
- The bootstrap app in `etc/apps` on each indexer should be removed once the app is established in `manager-apps` — having it in both places can cause configuration conflicts
- `pass4SymmKey` in cleartext in a config file will be automatically encrypted by Splunk on next start — this is the correct way to set it initially