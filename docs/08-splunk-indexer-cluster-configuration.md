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

## App Overview

| App | Destination | Purpose |
|---|---|---|
| `pait_cluster_manager_base` | mgmt-2 `etc/apps` | Cluster Manager and indexer discovery configuration |
| `pait_cluster_indexer_base` | mgmt-2 `manager-apps` (after bootstrap) | Indexer peer configuration, inputs, web |
| `pait_all_indexes` | mgmt-2 `manager-apps` | Index definitions with volume configuration — indexers only |
| `pait_all_search_indexes` | mgmt-1 `shcluster/apps` | Lightweight index definitions for search head autocomplete |

> **Important:** Two separate index apps are required. `pait_all_indexes` uses volume references that only exist on indexers. Deploying it to search heads causes Splunk to crash on startup. `pait_all_search_indexes` uses `$SPLUNK_DB` variables instead and is safe to deploy to search heads.

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

[indexer_discovery]
pass4SymmKey = <indexer_discovery_secret>
indexerWeightByDiskCapacity = true
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

This app bootstraps the indexer peers to the cluster and configures indexer-specific settings. It does not contain index definitions — those live in `pait_all_indexes`.

App structure:
```
pait_cluster_indexer_base/
    default/
        server.conf
        inputs.conf
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

`default/web.conf`:
```ini
[settings]
startwebserver = 0
```

---

## Step 4 — Build pait_all_indexes

This app contains all index definitions and volume configuration. It is deployed to the indexer cluster only.

App structure:
```
pait_all_indexes/
    default/
        indexes.conf
    metadata/
        default.meta
        local.meta
```

`default/indexes.conf`:
```ini
[volume:hot_tier]
path = /opt/splunkdata/hot
maxVolumeDataSizeMB = 2000

[volume:cold_tier]
path = /opt/splunkdata/cold
maxVolumeDataSizeMB = 5000

[default]
repFactor = auto
tsidxWritingLevel = 4
homePath   = volume:hot_tier/$_index_name/db
coldPath   = volume:cold_tier/$_index_name/colddb
thawedPath = /opt/splunkdata/thawed/$_index_name/thaweddb

[linux_audit]
maxTotalDataSizeMB = 5120
frozenTimePeriodInSecs = 2592000

[linux_logs]
maxTotalDataSizeMB = 5120
frozenTimePeriodInSecs = 2592000

[nginx_access]
maxTotalDataSizeMB = 5120
frozenTimePeriodInSecs = 2592000
```

**Notes:**
- `tsidxWritingLevel = 4` enables the latest TSIDX format for improved search performance
- `journalCompression` defaults to `zstd` in 10.4 — no need to specify explicitly
- `frozenTimePeriodInSecs = 2592000` = 30 days retention
- Volume sizes are conservative for lab use — adjust as needed

---

## Step 5 — Build pait_all_search_indexes

This app provides index definitions to the search head cluster for search autocomplete. It uses `$SPLUNK_DB` and `$_index_name` variables instead of volume references — this is critical. Deploying `pait_all_indexes` with volume references to search heads causes Splunk to crash on startup because `/opt/splunkdata` does not exist on search heads.

App structure:
```
pait_all_search_indexes/
    default/
        indexes.conf
    metadata/
        default.meta
        local.meta
```

`default/indexes.conf`:
```ini
[default]
homePath   = $SPLUNK_DB/$_index_name/db
coldPath   = $SPLUNK_DB/$_index_name/colddb
thawedPath = $SPLUNK_DB/$_index_name/thaweddb

[linux_audit]

[linux_logs]

[nginx_access]
```

**Notes:**
- Empty stanzas are intentional — all path settings inherit from `[default]`
- `$SPLUNK_DB` resolves to `/opt/splunk/var/lib/splunk` automatically
- `$_index_name` resolves to the stanza name automatically
- Search heads will create these directories locally but never store data in them — all data resides on the indexers
- No `repFactor`, no volume references, no size limits — search heads do not need these settings

---

## Step 6 — Bootstrap Indexer Peers

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
sudo vi /opt/splunk/etc/apps/pait_cluster_indexer_base/default/server.conf

sudo systemctl start Splunkd
```

**Verify peers registered:** In the Cluster Manager UI both indexers should appear as peers with status `Up`.

---

## Step 7 — Move to Manager-Apps and Deploy Index Apps

Once peers are registered, move `pait_cluster_indexer_base` to `manager-apps`, deploy `pait_all_indexes` to the indexer cluster, and deploy `pait_all_search_indexes` to the search head cluster.

### Indexer cluster (on mgmt-2)

```bash
# Move cluster indexer base to manager-apps
sudo cp -r /tmp/pait_cluster_indexer_base /opt/splunk/etc/manager-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/manager-apps/pait_cluster_indexer_base

# Copy pait_all_indexes to manager-apps
vagrant scp ./splunk/apps/pait_all_indexes mgmt-2:/tmp/
sudo cp -r /tmp/pait_all_indexes /opt/splunk/etc/manager-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/manager-apps/pait_all_indexes

# Validate and push bundle to indexers
sudo -u splunk /opt/splunk/bin/splunk validate cluster-bundle
sudo -u splunk /opt/splunk/bin/splunk apply cluster-bundle --answer-yes
```

### Remove bootstrap app from each indexer

```bash
# On idx-1 and idx-2
sudo rm -rf /opt/splunk/etc/apps/pait_cluster_indexer_base
sudo systemctl restart Splunkd
```

### Search head cluster (on mgmt-1)

```bash
vagrant scp ./splunk/apps/pait_all_search_indexes mgmt-1:/tmp/
sudo cp -r /tmp/pait_all_search_indexes /opt/splunk/etc/shcluster/apps/
sudo chown -R splunk:splunk /opt/splunk/etc/shcluster/apps/pait_all_search_indexes
sudo -u splunk /opt/splunk/bin/splunk apply shcluster-bundle \
  -target https://192.168.248.207:8089 \
  --answer-yes
```

**Verify indexes visible on search heads:**

Navigate to **Settings → Indexes** on any search head — `linux_audit`, `linux_logs`, and `nginx_access` should appear with autocomplete working in the search bar.

---

## Step 8 — Verify License Manager

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

## Adding New Indexes

When adding a new index to the environment always update both apps:

1. Add stanza to `pait_all_indexes/default/indexes.conf` with size and retention settings
2. Add empty stanza to `pait_all_search_indexes/default/indexes.conf`
3. Deploy `pait_all_indexes` to indexer cluster — mgmt-2 `manager-apps` → validate → apply bundle
4. Deploy `pait_all_search_indexes` to search head cluster — mgmt-1 `shcluster/apps` → apply bundle

---

## Troubleshooting

**Search head crashes on startup after deploying index app:**
The index app deployed to search heads contains volume references (`volume:hot_tier`) that cannot be resolved because `/opt/splunkdata` does not exist on search heads. Remove the app from `shcluster/apps` on the deployer, push an empty bundle to clear it from the search heads, then deploy `pait_all_search_indexes` instead which uses `$SPLUNK_DB` variables.

**503 error when applying shcluster-bundle:**
The SHC captain is temporarily unavailable — typically occurs after manually stopping and restarting search heads. Wait 30-60 seconds for captain re-election to complete and retry. The bundle push will succeed once a captain is elected.

**`Cannot load IndexConfig: Required parameter=homePath not configured`:**
An index stanza is present without path settings and no `[default]` stanza to inherit from. Ensure `pait_all_search_indexes` includes the `[default]` stanza with `$SPLUNK_DB` paths.

**Peers not registering after start:**
Check `pass4SymmKey` matches between CM and indexers. Check `manager_uri` is correct and port 8089 is reachable.
```bash
sudo tail -100 /opt/splunk/var/log/splunk/splunkd.log | grep -i "cluster\|peer\|manager"
```

**Bundle push fails:**
Validate first:
```bash
sudo -u splunk /opt/splunk/bin/splunk validate cluster-bundle
```

**Peers go down after bundle push:**
Check for duplicate apps in `etc/apps` on the indexers conflicting with apps in the bundle. Remove duplicates and restart.

**Encrypted pass4SymmKey looks different across nodes:**
Expected and correct. Splunk uses non-deterministic encryption. Use `show-decrypted` to verify all nodes decrypt to the same plaintext value.

**License peers not showing in UI:**
Use `splunk list licenser-slaves` on the CLI for immediate verification. The UI may take a few minutes to update.

---

## Notes

- Never deploy `pait_all_indexes` to search heads — it will crash Splunk on startup due to unresolvable volume references
- `pait_all_search_indexes` is the correct app for search heads — uses `$SPLUNK_DB` and `$_index_name` variables
- When adding new indexes always update both apps and redeploy to both tiers
- Apps in `manager-apps` are never run locally on the Cluster Manager — only distributed to peers via bundle
- Always validate the indexer cluster bundle before applying
- Do not use `splunk restart` on peer nodes once replication has begun — use `systemctl restart Splunkd`
- `pass4SymmKey` in cleartext will be automatically encrypted by Splunk on next start