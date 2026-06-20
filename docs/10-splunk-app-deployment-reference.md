# App Deployment Reference

This document is a quick reference for deploying configuration apps to the indexer cluster and search head cluster in the PlayAroundIT Observability Lab.

---

## Indexer Cluster — Deploy via Cluster Manager (mgmt-2)

Apps deployed to the indexer cluster are placed in the `manager-apps` directory on mgmt-2 and pushed to all indexer peers via the configuration bundle mechanism.

### 1. Copy the app to mgmt-2

```bash
# From Windows host
vagrant scp ./splunk/apps/<app_name> mgmt-2:/tmp/
```

### 2. Move to manager-apps on mgmt-2

```bash
sudo cp -r /tmp/<app_name> /opt/splunk/etc/manager-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/manager-apps/<app_name>
```

### 3. Validate the bundle

Always validate before applying — this catches config errors before they reach the peers:

```bash
sudo -u splunk /opt/splunk/bin/splunk validate cluster-bundle
```

### 4. Apply the bundle

```bash
sudo -u splunk /opt/splunk/bin/splunk apply cluster-bundle --answer-yes
```

### 5. Verify bundle was applied to peers

```bash
sudo -u splunk /opt/splunk/bin/splunk show cluster-bundle-status
```

### 6. Verify app is present on indexers

```bash
# SSH into idx-1 or idx-2
ls /opt/splunk/etc/apps/ | grep <app_name>
```

---

## Search Head Cluster — Deploy via SH Deployer (mgmt-1)

Apps deployed to the search head cluster are placed in the `shcluster/apps` directory on mgmt-1 and pushed to all SHC members via the bundle mechanism.

### 1. Copy the app to mgmt-1

```bash
# From Windows host
vagrant scp ./splunk/apps/<app_name> mgmt-1:/tmp/
```

### 2. Move to shcluster/apps on mgmt-1

```bash
sudo cp -r /tmp/<app_name> /opt/splunk/etc/shcluster/apps/
sudo chown -R splunk:splunk /opt/splunk/etc/shcluster/apps/<app_name>
```

### 3. Apply the SHC bundle

```bash
sudo -u splunk /opt/splunk/bin/splunk apply shcluster-bundle \
  -target https://192.168.248.207:8089 \
  --answer-yes
```

> **Note:** The `-target` parameter specifies any SHC member — the deployer pushes to all members automatically. Point to the current captain when possible.

### 4. Verify bundle applied — check SHC status

```bash
sudo -u splunk /opt/splunk/bin/splunk show shcluster-status
```

There is no dedicated `shcluster-bundle-status` command. Use `show shcluster-status` to confirm members are up and in sync after a bundle push.

### 5. Verify app is present on search heads

```bash
# SSH into sh-1 or sh-2
ls /opt/splunk/etc/apps/ | grep <app_name>
```

---

## Deploying to Both Tiers

For apps that need to be on both the indexer cluster and the search head cluster
(e.g. `pait_all_indexes` for index autocomplete on search heads):

```bash
# Step 1 — Copy to both nodes from Windows host
vagrant scp ./splunk/apps/<app_name> mgmt-2:/tmp/
vagrant scp ./splunk/apps/<app_name> mgmt-1:/tmp/

# Step 2 — Deploy to indexer cluster (on mgmt-2)
sudo tar -xzf splunk-add-on-for-unix-and-linux_*.tgz
sudo cp -r /tmp/<app_name> /opt/splunk/etc/manager-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/manager-apps/<app_name>
sudo -u splunk /opt/splunk/bin/splunk validate cluster-bundle
sudo -u splunk /opt/splunk/bin/splunk apply cluster-bundle --answer-yes

# Step 3 — Deploy to search head cluster (on mgmt-1)
sudo tar -xzf splunk-add-on-for-unix-and-linux_*.tgz
sudo cp -r /tmp/<app_name> /opt/splunk/etc/shcluster/apps/
sudo chown -R splunk:splunk /opt/splunk/etc/shcluster/apps/<app_name>
sudo -u splunk /opt/splunk/bin/splunk apply shcluster-bundle \
  -target https://192.168.248.207:8089 \
  --answer-yes
```

---

## Deploying to Agent Management (mgmt-1)

For apps deployed to Universal Forwarders via Agent Management:

```bash
# Step 1 — Copy to mgmt-1
vagrant scp ./splunk/apps/<app_name> mgmt-1:/tmp/

# Step 2 — Place in deployment-apps
sudo tar -xzf splunk-add-on-for-unix-and-linux_*.tgz
sudo cp -r /tmp/<app_name> /opt/splunk/etc/deployment-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/deployment-apps/<app_name>

# Step 3 — Reload deploy server
sudo -u splunk /opt/splunk/bin/splunk reload deploy-server
```

Then assign the app to the appropriate server class in the Agent Management UI.

---

## Quick Reference — Key Directories

| Tier | Node | Directory | Purpose |
|---|---|---|---|
| Indexer cluster | mgmt-2 | `/opt/splunk/etc/manager-apps/` | Apps pushed to indexer peers via bundle |
| Search head cluster | mgmt-1 | `/opt/splunk/etc/shcluster/apps/` | Apps pushed to SHC members via bundle |
| Agent Management | mgmt-1 | `/opt/splunk/etc/deployment-apps/` | Apps pushed to UFs via Agent Management |
| Local (any node) | any | `/opt/splunk/etc/apps/` | Apps running locally on that instance only |

---

## Quick Reference — Indexer Cluster Commands

| Command | Node | Purpose |
|---|---|---|
| `splunk validate cluster-bundle` | mgmt-2 | Validate indexer bundle before applying |
| `splunk apply cluster-bundle` | mgmt-2 | Push bundle to indexer peers |
| `splunk show cluster-bundle-status` | mgmt-2 | Check bundle deployment status on peers |
| `splunk show cluster-status` | mgmt-2 | Show overall indexer cluster health |
| `splunk show cluster-peers` | mgmt-2 | List all indexer peers |

---

## Quick Reference — Search Head Cluster Commands

Reference: Splunk official CLI commands for search head clustering (10.4)

| Command | Run On | Purpose |
|---|---|---|
| `splunk init shcluster-config` | new member | Initialize a search head as an SHC member |
| `splunk bootstrap shcluster-captain -servers_list` | new captain | Manually assign captain and set member list |
| `splunk add shcluster-member -current_member_uri` | new member | Add this search head to an existing SHC |
| `splunk add shcluster-member -new_member_uri` | any member | Add a new search head to an existing SHC |
| `splunk show shcluster-status` | any member | Show overall SHC status — captain, members, sync state |
| `splunk list shcluster-members` | any member | List all SHC members |
| `splunk apply shcluster-bundle` | deployer | Push app bundle to all SHC members |
| `splunk rolling-restart shcluster-members` | any member | Cleanly restart all SHC members in sequence |
| `splunk resync shcluster-replicated-config` | any member | Help a member get back in sync |
| `splunk remove shcluster-member` | member | Remove this instance from the SHC |
| `splunk remove shcluster-member -mgmt_uri` | any instance | Remove a specific member from another instance |
| `splunk disable shcluster-config` | member | Permanently disable SHC on this instance |
| `splunk diag` | captain | Run diagnostics on the SHC captain |

---

## App Context and Indexer Deployment — Important Gotcha

Any app that contains saved searches, reports, or is used as a search context
must exist on **both** the search head cluster and the indexer cluster — even
if the app has no indexer-specific configuration.

### Why This Is Required

When a search runs from within a specific app context, Splunk dispatches parts
of the search to the indexers. The indexers execute their portion in the **same
app context** as the search head. If the app does not exist on the indexer,
the search process fails with:

```bash
exit_code=111, description="exited with error: Application does not exist: <app_name>"
```

This happens even if the app has `export = system` in `app.conf` and even if
the search contains no app-specific knowledge objects.

### The Rule

| App contains | Search heads | Indexers |
|---|---|---|
| Saved searches / reports | Required | Required (stub minimum) |
| Dashboards only | Required | Required (stub minimum) |
| Field extractions / lookups | Required | Required (full deployment) |
| Inputs | Not required | Required (inputs disabled) |

A **stub** deployment means the app only needs `app.conf` on the indexers —
no inputs, no lookups, no dashboards. Just enough for the indexers to
recognise the app context.

### Deploying a Stub to the Indexer Cluster

```bash
# On mgmt-2 — copy app to manager-apps
sudo cp -r /tmp/<app_name> /opt/splunk/etc/manager-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/manager-apps/<app_name>

# Validate and push bundle
sudo -u splunk /opt/splunk/bin/splunk validate cluster-bundle
sudo -u splunk /opt/splunk/bin/splunk apply cluster-bundle --answer-yes
```

The indexers only need the `default/app.conf` and `metadata/` files.
Everything else (dashboards, saved searches, panels) can be omitted from
the indexer deployment.

### Verifying the App Exists on Indexers

After the bundle push confirm the app is present on the indexers:

```bash
# SSH into idx-1 or idx-2
ls /opt/splunk/etc/apps/ | grep <app_name>
```

If the app is missing from the indexer the search will fail with exit code 111
regardless of the search head configuration.

---

## Quick Reference — Agent Management Commands

| Command | Node | Purpose |
|---|---|---|
| `splunk reload deploy-server` | mgmt-1 | Apply server class changes without restart |
| `splunk display deploy-server` | mgmt-1 | Confirm Agent Management is enabled |
| `splunk set deploy-poll <uri>` | any UF | Set the Agent Management server address |

---

## Notes

- Always validate the indexer cluster bundle before applying — `validate` catches errors before they reach peers
- There is no `shcluster-bundle-status` command — use `show shcluster-status` to verify SHC bundle deployment
- The `-target` in `apply shcluster-bundle` should point to any SHC member — the deployer pushes to all members automatically
- Apps in `manager-apps` are never run locally on the Cluster Manager — they are only distributed to peers
- Apps in `shcluster/apps` are never run locally on the Deployer — they are only distributed to SHC members
- After `apply cluster-bundle` indexers restart their Splunk processes to pick up the new config — expect brief unavailability
- After `apply shcluster-bundle` a rolling restart may occur on the search heads depending on the nature of the config change
- `splunk rolling-restart shcluster-members` is the safe way to restart all search heads — it restarts them one at a time to maintain search availability