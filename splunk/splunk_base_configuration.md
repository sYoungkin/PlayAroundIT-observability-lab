# Splunk Base Configuration Apps

This document describes the configuration apps used to configure the Splunk 10.4 clustered environment in the PlayAroundIT Observability Lab. All apps follow current Splunk 10.4 best practices and terminology.

---

## Naming Convention

All apps use the `pait_` prefix (PlayAroundIT) instead of the generic `org_` prefix found in the Splunk base configuration templates. Apps were built using Splunk-provided templates as a reference and updated to reflect current 10.4 terminology and best practices.

**Key terminology changes from older versions:**
- `mode = master` → `mode = manager`
- `master_uri` → `manager_uri`
- `mode = slave` → `mode = peer`

---

## App Inventory

### Cluster Apps (from `Base Configs Clustered` templates)

| App | Based On | Destination | Purpose |
|---|---|---|---|
| `pait_cluster_manager_base` | `org_cluster_manager_base` | mgmt-2 `/opt/splunk/etc/apps` | Cluster Manager configuration |
| `pait_cluster_indexer_base` | `org_cluster_indexer_base` | mgmt-2 `/opt/splunk/etc/manager-apps` | Indexer peer configuration — pushed via CM bundle |
| `pait_cluster_search_base` | `org_cluster_search_base` | sh-1, sh-2 `/opt/splunk/etc/apps` | Search head cluster member configuration |
| `pait_cluster_forwarder_outputs` | `org_cluster_forwarder_outputs` | mgmt-1, mgmt-2, sh-1, sh-2 `/opt/splunk/etc/apps` | Forward internal Splunk logs to indexer layer |

### General Base Apps

| App | Based On | Destination | Purpose |
|---|---|---|---|
| `pait_all_indexes` | `org_all_indexes` | mgmt-2 `/opt/splunk/etc/manager-apps` | Index definitions — pushed via CM bundle |
| `pait_all_indexer_base` | `org_all_indexer_base` | mgmt-2 `/opt/splunk/etc/manager-apps` | Indexer base settings — pushed via CM bundle |
| `pait_all_search_base` | `org_all_search_base` | sh-1, sh-2 `/opt/splunk/etc/apps` | Search head base settings |

### New Apps (no template — built from scratch)

| App | Destination | Purpose |
|---|---|---|
| `pait_shc_deployer_base` | mgmt-1 `/opt/splunk/etc/apps` | Search Head Deployer configuration |
| `pait_deployment_server_base` | mgmt-1 `/opt/splunk/etc/apps` | Deployment Server serverclass configuration |

---

## App Structure

Every app follows the standard Splunk app directory structure:

```
pait_<app_name>/
    default/
        <config_files>.conf
    metadata/
        default.meta
        local.meta
```

The `metadata/` directory is required in every app. Without it Splunk may not correctly apply permissions and access controls to the app's configuration objects.

### metadata/default.meta

Controls access permissions for the app's knowledge objects. Minimum content:

```
[]
access = read : [ * ], write : [ admin ]
```

### metadata/local.meta

Used for local overrides of metadata. Should exist but can be empty:

```
# local.meta
```

---

## Configuration Details

### pait_cluster_manager_base

**Destination:** mgmt-2 `/opt/splunk/etc/apps`

`default/server.conf`:

```ini
[clustering]
mode = manager
replication_factor = 2
search_factor = 2
pass4SymmKey = <indexer_cluster_secret>
cluster_label = pait_cluster1
```

**Notes:**
- `mode = manager` is the current 10.4 terminology (previously `mode = master`)
- `replication_factor = 2` requires at least 2 indexer peers
- `search_factor = 2` requires at least 2 searchable copies
- `pass4SymmKey` must match on all cluster peers and search heads connecting to this cluster
- `cluster_label` is used by the Monitoring Console to identify the cluster

---

### pait_cluster_indexer_base

**Destination:** mgmt-2 `/opt/splunk/etc/manager-apps` (deployed to peers via CM bundle)

`default/server.conf`:

```ini
[clustering]
mode = peer
manager_uri = https://<mgmt2_ip>:8089
pass4SymmKey = <indexer_cluster_secret>

[replication_port://9100]
disabled = false
```

**Notes:**
- `mode = peer` is the current 10.4 terminology (previously `mode = slave`)
- `manager_uri` is the current 10.4 terminology (previously `master_uri`)
- Replication port `9100` is used for bucket replication between peers
- This app lives in `manager-apps` on the CM and is pushed to all peers via the configuration bundle

`default/inputs.conf`:

```ini
[splunktcp://9997]
disabled = false
```

---

### pait_cluster_search_base

**Destination:** sh-1, sh-2 `/opt/splunk/etc/apps`

`default/server.conf`:

```ini
[clustering]
mode = searchhead
manager_uri = https://<mgmt2_ip>:8089
pass4SymmKey = <indexer_cluster_secret>
```

**Notes:**
- Search heads connect to the Cluster Manager to discover indexer peers for distributed search
- `pass4SymmKey` must match the indexer cluster secret

---

### pait_cluster_forwarder_outputs

**Destination:** mgmt-1, mgmt-2, sh-1, sh-2 `/opt/splunk/etc/apps`

`default/outputs.conf`:

```ini
[tcpout]
defaultGroup = primary_indexers
forceTimebasedAutoLB = true

[tcpout:primary_indexers]
server = <idx1_ip>:9997,<idx2_ip>:9997
compressed = true

[indexAndForward]
index = false
```

**Notes:**
- Forwards internal Splunk logs from management and search head nodes to the indexer layer
- `index = false` disables local indexing on non-indexer nodes
- `forceTimebasedAutoLB = true` ensures time-based load balancing across indexers

---

### pait_all_indexes

**Destination:** mgmt-2 `/opt/splunk/etc/manager-apps` (deployed to peers via CM bundle)

`default/indexes.conf`:

```ini
[default]
repFactor = auto
journalCompression = zstd
tsidxWritingLevel = 4

[main]
homePath = $SPLUNK_DB/defaultdb/db
coldPath = $SPLUNK_DB/defaultdb/colddb
thawedPath = $SPLUNK_DB/defaultdb/thaweddb
maxTotalDataSizeMB = 5120
frozenTimePeriodInSecs = 604800
```

**Notes:**
- `repFactor = auto` tells the indexer to use the cluster replication factor
- `journalCompression = zstd` is the recommended compression algorithm in 10.4
- `tsidxWritingLevel = 4` enables the latest TSIDX format for improved search performance
- Index size and retention are set conservatively for the lab environment

---

### pait_all_indexer_base

**Destination:** mgmt-2 `/opt/splunk/etc/manager-apps` (deployed to peers via CM bundle)

`default/indexes.conf`:

```ini
[default]
repFactor = auto
journalCompression = zstd
tsidxWritingLevel = 4
```

---

### pait_all_search_base

**Destination:** sh-1, sh-2 `/opt/splunk/etc/apps`

`default/limits.conf`:

```ini
[search]
max_searches_per_cpu = 1
```

---

### pait_shc_deployer_base

**Destination:** mgmt-1 `/opt/splunk/etc/apps`

`default/server.conf`:

```ini
[shclustering]
pass4SymmKey = <shc_secret>
shcluster_label = pait_shcluster1
```

**Notes:**
- The Search Head Deployer uses a separate `pass4SymmKey` from the indexer cluster
- `shcluster_label` identifies the SHC in the Monitoring Console

---

### pait_deployment_server_base

**Destination:** mgmt-1 `/opt/splunk/etc/apps`

`default/serverclass.conf`:

```ini
[serverClass:pait_linux_ufs]
whitelist.0 = uf-*

[serverClass:pait_linux_ufs:app:pait_uf_outputs]
restartSplunkWeb = false
restartSplunkd = true
stateOnClient = enabled
```

---

## Deployment Order

The correct order for deploying and starting the cluster is:

1. **Configure Splunk secrets** on all nodes before first start
2. **Deploy `pait_cluster_manager_base`** to mgmt-2 and start Splunk on mgmt-2
3. **Deploy `pait_cluster_indexer_base`** and `pait_all_indexes` to `manager-apps` on mgmt-2
4. **Start idx-1 and idx-2** — peers register with Cluster Manager
5. **Push CM configuration bundle** to peers
6. **Deploy `pait_cluster_search_base`** and `pait_cluster_forwarder_outputs` to sh-1, sh-2
7. **Deploy `pait_shc_deployer_base`** to mgmt-1 and configure SHC
8. **Bootstrap search head cluster** — initialize captain
9. **Start sh-1 and sh-2** and join SHC
10. **Deploy `pait_cluster_forwarder_outputs`** to mgmt-1, mgmt-2
11. **Configure License Manager** on mgmt-2
12. **Configure Monitoring Console** on mgmt-2
13. **Configure Deployment Server** on mgmt-1

---

## Notes

- All `pass4SymmKey` values must be set **before** any Splunk instance starts for the first time
- The indexer cluster uses one shared secret — the search head cluster uses a separate secret
- Apps in `manager-apps` are never run locally on the Cluster Manager — they are only distributed to peers via the configuration bundle
- Configuration bundle must be validated and pushed after any change to `manager-apps`
- All app config files must contain at least one stanza header — empty files are not recognized by Splunk
- All apps must have a `metadata/` directory with `default.meta` and `local.meta`