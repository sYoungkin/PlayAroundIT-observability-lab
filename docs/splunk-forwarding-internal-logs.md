# Forwarding Internal Logs to the Indexer Layer

This document covers the configuration of internal log forwarding from all non-indexing Splunk nodes to the indexer layer, including enabling indexer discovery on the Cluster Manager and deploying the forwarder outputs app.

This is a Splunk best practice for distributed deployments. All Splunk Enterprise instances that are not indexers should forward their internal logs (`_internal`, `_audit`, `_introspection` etc.) to the indexer layer rather than indexing them locally. This ensures all internal telemetry is searchable from the search heads and stored with proper replication.

Reference: [Best practice: Forward search head data to the indexer layer](https://help.splunk.com/en/splunk-enterprise/administer/distributed-search/10.4/deploy-distributed-search/best-practice-forward-search-head-data-to-the-indexer-layer)

---

## Architecture

| Node | Role | Action |
|---|---|---|
| mgmt-2 | Cluster Manager | Enable indexer discovery |
| mgmt-1 | Search Head Deployer | Forward internal logs, disable local indexing |
| mgmt-2 | Cluster Manager / License Manager | Forward internal logs, disable local indexing |
| sh-1 | Search Head | Forward internal logs, disable local indexing |
| sh-2 | Search Head | Forward internal logs, disable local indexing |

---

## Step 1 — Enable Indexer Discovery on the Cluster Manager

Indexer discovery allows forwarders to dynamically obtain the list of available indexer peers from the Cluster Manager rather than having hardcoded indexer IPs in their outputs configuration. This is the recommended approach for indexer cluster environments.

**Update `pait_cluster_manager_base/default/server.conf` on mgmt-2:**

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

**Notes:**
- The `pass4SymmKey` under `[indexer_discovery]` is a separate secret from the clustering key — forwarders present this key when requesting the indexer list from the CM
- `indexerWeightByDiskCapacity = true` distributes forwarded data to indexers proportionally based on available disk capacity
- Use a different secret for indexer discovery than the clustering secret — keeps the two purposes cleanly separated

**Restart Splunk on mgmt-2:**

```bash
sudo systemctl restart Splunkd
```

**Verify indexer discovery is configured:**

```bash
grep -A3 "indexer_discovery" /opt/splunk/etc/apps/pait_cluster_manager_base/default/server.conf
```

Once forwarders connect via indexer discovery they will appear in the Cluster Manager UI under **Indexer Clustering → Forwarders**.

---

## Step 2 — Build pait_cluster_forwarder_outputs

This app is deployed to all non-indexing Splunk Enterprise nodes — mgmt-1, mgmt-2, sh-1, sh-2.

**App structure:**
```
pait_cluster_forwarder_outputs/
    default/
        outputs.conf
    metadata/
        default.meta
        local.meta
```

`default/outputs.conf`:
```ini
[indexAndForward]
index = false

[tcpout]
defaultGroup = primary_indexers
forwardedindex.filter.disable = true
indexAndForward = false
forceTimebasedAutoLB = true
maxQueueSize = 7MB
useACK = true

[tcpout:primary_indexers]
indexerDiscovery = clustered_indexers
compressed = true

[indexer_discovery:clustered_indexers]
pass4SymmKey = <indexer_discovery_secret>
manager_uri = https://192.168.248.204:8089
```

`metadata/default.meta`:
```
[]
access = read : [ * ], write : [ admin ]
```

**Configuration notes:**

| Setting | Purpose |
|---|---|
| `[indexAndForward] index = false` | Disables local indexing on this node |
| `forwardedindex.filter.disable = true` | Disables the default filter that prevents internal indexes from being forwarded — required to forward `_internal`, `_audit` etc. |
| `indexAndForward = false` in `[tcpout]` | Documented Splunk best practice setting — works together with the `[indexAndForward]` stanza to ensure local indexing is fully disabled |
| `forceTimebasedAutoLB = true` | Enables time-based automatic load balancing across indexers |
| `maxQueueSize = 7MB` | Queue size for outbound data — provides buffer during indexer unavailability |
| `useACK = true` | Enables indexer acknowledgement — indexer confirms receipt before the forwarder removes data from its queue. Ensures data delivery |
| `indexerDiscovery = clustered_indexers` | Uses indexer discovery rather than hardcoded IPs — CM provides the current list of available indexers dynamically |
| `compressed = true` | Compresses data in transit to indexers |

---

## Step 3 — Deploy the App

### mgmt-1 and mgmt-2 — manual deployment

```bash
# From Windows host
vagrant scp ./splunk/apps/pait_cluster_forwarder_outputs mgmt-1:/tmp/
vagrant scp ./splunk/apps/pait_cluster_forwarder_outputs mgmt-2:/tmp/
```

On each management node:
```bash
sudo cp -r /tmp/pait_cluster_forwarder_outputs /opt/splunk/etc/apps/
sudo chown -R splunk:splunk /opt/splunk/etc/apps/pait_cluster_forwarder_outputs
sudo systemctl restart Splunkd
```

### sh-1 and sh-2 — deploy via SH Deployer

**Encrypt the indexer discovery pass4SymmKey on mgmt-1 before deploying:**

```bash
sudo -u splunk /opt/splunk/bin/splunk show-encrypted \
  --value 'yourindexerdiscoverykey'
```

Copy the `$7$...` output and replace the cleartext value in `outputs.conf` before placing in `shcluster/apps`.

```bash
# On mgmt-1 — copy to shcluster staging directory
sudo cp -r /tmp/pait_cluster_forwarder_outputs /opt/splunk/etc/shcluster/apps/
sudo chown -R splunk:splunk /opt/splunk/etc/shcluster/apps/pait_cluster_forwarder_outputs

# Edit to add encrypted pass4SymmKey
sudo vi /opt/splunk/etc/shcluster/apps/pait_cluster_forwarder_outputs/default/outputs.conf

# Apply bundle to SHC
sudo -u splunk /opt/splunk/bin/splunk apply shcluster-bundle \
  -target https://192.168.248.207:8089 \
  --answer-yes
```

---

## Verification

### Confirm internal logs are being forwarded

From any search head, search for internal logs from a management or search head node:

```splunk
index=_internal host=mgmt-1 | head 20
index=_internal host=sh-1 | head 20
```

All nodes should return results — confirming internal logs are flowing to the indexers and being made searchable through the cluster.

### Confirm local indexing is disabled

```bash
# On mgmt-1 or sh-1 — should return no local data
ls /opt/splunk/var/lib/splunk/defaultdb/db/
```

After the app is deployed and Splunk is restarted, no new hot buckets should be created locally on non-indexing nodes.

### Confirm forwarders visible in Cluster Manager UI

Navigate to the Cluster Manager UI on mgmt-2 → **Indexer Clustering** → **Forwarders**. All four non-indexing nodes should appear as connected forwarders using indexer discovery.

### Verify indexer acknowledgement is working

Check the forwarder queue status:

```bash
index=_internal source=*metrics.log* group=queue name=tcpout_generic_queue | stats avg(current_size) by host
```

Queue sizes should remain low confirming data is being acknowledged and cleared by the indexers.

---

## Troubleshooting

**Internal logs not appearing in search:**
Confirm `forwardedindex.filter.disable = true` is set — without this Splunk's default filter prevents `_internal` and other internal indexes from being forwarded.

**Forwarders not appearing in CM UI:**
The `pass4SymmKey` under `[indexer_discovery:clustered_indexers]` in `outputs.conf` must match the `pass4SymmKey` under `[indexer_discovery]` in the CM's `server.conf`. Decrypt both with `show-decrypted` and compare.

**Data queue backing up:**
Check indexer connectivity. `useACK = true` means the forwarder waits for acknowledgement — if indexers are unreachable the queue will fill. Check `maxQueueSize` and indexer health.

**Search heads still indexing locally after deployment:**
Confirm the bundle was successfully pushed and the app is present in `etc/apps` on the search heads. Check `index = false` is in the `[indexAndForward]` stanza and restart Splunk on the affected node.

---

## Notes

- This configuration applies to all non-indexing Splunk Enterprise nodes — management nodes and search heads
- Indexer discovery is preferred over hardcoded indexer IPs — if an indexer is added or removed the CM automatically updates the list provided to forwarders
- The indexer discovery `pass4SymmKey` is separate from the clustering `pass4SymmKey` — use a different value for each
- Always pre-encrypt `pass4SymmKey` values using `show-encrypted` before deploying via the SH Deployer — values in `default/` are not auto-encrypted by Splunk
- Universal Forwarders use a similar but separate outputs configuration — see `docs/splunk-universal-forwarder-configuration.md`
EOF