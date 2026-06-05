# Splunk Search Head Cluster Configuration

This document covers the complete configuration of the Splunk 10.4 Search Head Cluster (SHC) in the PlayAroundIT Observability Lab, including the Search Head Deployer, SHC member initialization, captain bootstrapping, and connection to the indexer cluster.

---

## Architecture

| Node | Role | IP |
|---|---|---|
| mgmt-1 | Search Head Deployer | 192.168.248.203 |
| sh-1 | SHC Member, Captain | 192.168.248.207 |
| sh-2 | SHC Member | 192.168.248.208 |

**SHC settings:**
- Replication factor: 2
- SHC label: `playaroundit_shc`
- Captain election: dynamic
- Connected to indexer cluster via Cluster Manager on mgmt-2

---

## Prerequisites

Before configuring the SHC:

1. Splunk 10.4 installed on mgmt-1, sh-1, sh-2
2. `splunk.secret` synchronized across the search head tier (mgmt-1, sh-1, sh-2) — see `docs/splunk-secret-synchronization.md`
3. Indexer cluster healthy and running — see `docs/splunk-indexer-cluster-configuration.md`
4. Splunk started on mgmt-1

---

## Phase 1 — Configure the Search Head Deployer (mgmt-1)

The deployer is not a member of the SHC. It holds the shared secret and label, and serves as the staging point for pushing configuration apps to SHC members.

**Edit `/opt/splunk/etc/system/local/server.conf` on mgmt-1:**

```ini
[shclustering]
pass4SymmKey = <shc_secret>
shcluster_label = playaroundit_shc

[license]
manager_uri = https://192.168.248.204:8089
```

**Restart Splunk on mgmt-1:**

```bash
sudo systemctl restart Splunkd
```

> **Note:** The deployer does not join the SHC. Running `splunk show shcluster-status` on mgmt-1 will return "search head clustering is not enabled on this instance" — this is correct and expected behavior.

> **Note:** The CLI command `splunk edit shcluster-config` may create the `[shclustering]` stanza but fail to write the settings underneath it in some 10.4 builds. Edit `server.conf` directly instead.

---

## Phase 2 — Initialize SHC Members

Run on sh-1 (replace IPs with actual values):

```bash
sudo /opt/splunk/bin/splunk init shcluster-config \
  -mgmt_uri https://192.168.248.207:8089 \
  -replication_port 9200 \
  -replication_factor 2 \
  -shcluster_label playaroundit_shc \
  -secret 'yourshcsecrethere' \
  -conf_deploy_fetch_url https://192.168.248.203:8089
```

Run on sh-2:

```bash
sudo /opt/splunk/bin/splunk init shcluster-config \
  -mgmt_uri https://192.168.248.208:8089 \
  -replication_port 9200 \
  -replication_factor 2 \
  -shcluster_label playaroundit_shc \
  -secret 'yourshcsecrethere' \
  -conf_deploy_fetch_url https://192.168.248.203:8089
```

Restart both search heads:

```bash
sudo systemctl restart Splunkd
```

> **Important:** The `-secret` value must be passed as the raw plaintext key — do not include `pass4SymmKey=` as part of the value. The error `Parameters must be in the form '-parameter value'` is caused by accidentally passing `pass4SymmKey=yourkey` instead of just `yourkey`.

---

## Phase 3 — Bootstrap the SHC Captain

Run from sh-1 after both members are up:

```bash
sudo /opt/splunk/bin/splunk bootstrap shcluster-captain \
  -servers_list "https://192.168.248.207:8089,https://192.168.248.208:8089"
```

**Verify SHC status from either search head:**

```bash
sudo -u splunk /opt/splunk/bin/splunk show shcluster-status
```

Expected output shows:
- One node elected as captain with `dynamic_captain: 1`
- Both members listed with `status: Up`
- `service_ready_flag: 1`

---

## Phase 4 — Connect Search Heads to Indexer Cluster

Create and deploy `pait_cluster_search_base` through the deployer to connect the search heads to the indexer cluster.

### Build the app

**App structure:**
```
pait_cluster_search_base/
    default/
        server.conf
    metadata/
        default.meta
        local.meta
```

`default/server.conf`:
```ini
[clustering]
mode = searchhead
manager_uri = https://192.168.248.204:8089
pass4SymmKey = <indexer_cluster_secret>
multisite = false

[license]
manager_uri = https://192.168.248.204:8089
```

`metadata/default.meta`:
```
[]
access = read : [ * ], write : [ admin ]
```

### Encrypt the pass4SymmKey before deploying

Since mgmt-1 shares the same `splunk.secret` as the search heads, encrypting the key on the deployer produces a value the search heads can decrypt.

Use `show-encrypted` to encrypt the plaintext key:

```bash
sudo -u splunk /opt/splunk/bin/splunk show-encrypted \
  --value 'yourplaintextindexerclusterkey'
```

Copy the `$7$...` output and replace `changeme` in `server.conf` with this encrypted value. The search heads will be able to decrypt it because they share the same `splunk.secret`.

### Deploy to mgmt-1 and push bundle

```bash
# From Windows host
vagrant scp ./splunk/apps/pait_cluster_search_base mgmt-1:/tmp/

# On mgmt-1 — move to shcluster/apps staging directory
sudo cp -r /tmp/pait_cluster_search_base /opt/splunk/etc/shcluster/apps/
sudo chown -R splunk:splunk /opt/splunk/etc/shcluster/apps/pait_cluster_search_base

# Add the encrypted pass4SymmKey to server.conf
sudo vi /opt/splunk/etc/shcluster/apps/pait_cluster_search_base/default/server.conf

# Apply the bundle to the SHC
sudo -u splunk /opt/splunk/bin/splunk apply shcluster-bundle \
  -target https://192.168.248.207:8089 \
  --answer-yes
```

> **Note:** Apps deployed via the deployer land in `default/` on the search heads. Splunk does not auto-encrypt `pass4SymmKey` values in `default/` — only in `local/`. Always pre-encrypt using `show-encrypted` on the deployer before deploying.

> **Note:** The deployer staging path is `/opt/splunk/etc/shcluster/apps/` — not `etc/apps/`. Apps placed in `etc/apps/` on mgmt-1 run locally on the deployer but are not pushed to search heads.

---

## Verification

### SHC health

```bash
# From either search head
sudo -u splunk /opt/splunk/bin/splunk show shcluster-status
```

### Deployer bundle status

```bash
# From mgmt-1
sudo -u splunk /opt/splunk/bin/splunk show shcluster-bundle-status
```

Both search heads should show the latest bundle applied.

### Confirm deployer address on search heads

```bash
grep conf_deploy_fetch_url /opt/splunk/etc/system/local/server.conf
```

### Confirm indexer cluster connection

On the Cluster Manager UI (mgmt-2) navigate to **Indexer Clustering** — both search heads should appear as connected search heads under the cluster.

### Verify bundle app deployed to search heads

```bash
ls /opt/splunk/etc/apps/ | grep pait_cluster_search_base
```

---

## Important Commands Reference

| Command | Purpose |
|---|---|
| `splunk init shcluster-config` | Initialize a node as an SHC member |
| `splunk bootstrap shcluster-captain` | Elect the initial captain |
| `splunk show shcluster-status` | Show SHC health and member status |
| `splunk show shcluster-bundle-status` | Show bundle deployment status from deployer |
| `splunk apply shcluster-bundle` | Push configuration bundle to SHC members |
| `splunk show-encrypted --value 'key'` | Encrypt a plaintext value using splunk.secret |
| `splunk show-decrypted --value '$7$...'` | Decrypt an encrypted value |

---

## Troubleshooting

**`Parameters must be in the form '-parameter value'` during init:**
The `-secret` parameter was passed with `pass4SymmKey=` prepended to the value. Pass only the raw key: `-secret 'yourkeyhere'` not `-secret 'pass4SymmKey=yourkeyhere'`.

**401 authentication error when applying shcluster-bundle:**
The `pass4SymmKey` on the deployer does not match the key used when initializing the search heads. Decrypt both values with `show-decrypted` and compare. Also verify `splunk.secret` md5sum matches across mgmt-1, sh-1, and sh-2.

**`pass4SymmKey` accidentally includes the key name as part of the value:**
When copying a key from a `server.conf` file, it's easy to accidentally copy `pass4SymmKey=yourkey` instead of just `yourkey`. Always decrypt and verify after setting any key.

**Deployer shows "search head clustering not enabled":**
This is correct — the deployer is not an SHC member. Use `show shcluster-status` on a search head, not on the deployer.

**Search heads not visible in Cluster Manager after deploying pait_cluster_search_base:**
Verify `pass4SymmKey` in the search head app matches the indexer cluster secret on mgmt-2. Use `show-decrypted` on both sides to confirm. Also check `manager_uri` points to the correct mgmt-2 IP and port 8089 is reachable.

**`last_conf_replication: Pending` on a search head member:**
Normal during initial SHC formation. The captain replicates configuration to members over time. Wait a few minutes and recheck status.

**Bundle push succeeds but app not appearing on search heads:**
Confirm the app was placed in `/opt/splunk/etc/shcluster/apps/` on the deployer, not in `etc/apps/`. Only apps in `shcluster/apps` are pushed to SHC members.

---

## Notes

- The deployer never joins the SHC — it is purely an administrative node for configuration distribution
- Apps pushed via the deployer land in `default/` on search heads — not `local/`
- `pass4SymmKey` is not auto-encrypted in `default/` — always pre-encrypt using `show-encrypted` on the deployer
- Sharing `splunk.secret` across mgmt-1 and the search heads ensures encrypted values produced on the deployer are portable to the search heads
- Captain election is dynamic — if the current captain goes down another member is automatically elected
- Do not run `splunk restart` on SHC members — use `systemctl restart Splunkd` or the rolling restart mechanism to avoid disrupting the cluster
- The `[clustering]` stanza in `pait_cluster_search_base` connects search heads to the indexer cluster — distributed search peer discovery is handled automatically through the Cluster Manager, not through the traditional Distributed Search peer configuration