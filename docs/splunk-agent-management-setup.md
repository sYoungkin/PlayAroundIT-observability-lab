# Agent Management — Initial Setup

This document covers the initial configuration of Splunk Agent Management (formerly Deployment Server) in the PlayAroundIT Observability Lab, including bootstrapping the Universal Forwarder, server class configuration, and the selective indexing requirement for the Agent Management node.

> **Terminology note:** Starting with Splunk 10.0, "Deployment Server" is now called "Agent Management" and "Deployment Client" is now called "Agent". The underlying functionality is unchanged. The name "deployment client" remains present in commands, `.conf` file names, and CLI interactions.

---

## Architecture

| Node | Role | IP |
|---|---|---|
| mgmt-1 | Agent Management (Deployment Server) | 192.168.248.203 |
| uf-1 | Universal Forwarder (Deployment Client / Agent) | 192.168.248.209 |

---

## How Agent Management Works

Any Splunk Enterprise instance can act as Agent Management — no explicit configuration is required to enable the role. The instance becomes an Agent Management server as soon as agents start phoning home to it.

Agents connect to the Agent Management server on the management port (8089) and phone home on a configurable interval (default 60 seconds). On each phone home the agent checks for new or updated apps assigned to its server class and downloads them if needed.

---

## Step 1 — Bootstrap the Universal Forwarder

The UF needs to know where to phone home. This is configured in `deploymentclient.conf`.

**Current config on uf-1 (`system/local/deploymentclient.conf`):**

```ini
[deployment-client]

[target-broker:deploymentServer]
targetUri = 192.168.248.203:8089
```

This was set using the Splunk CLI:

```bash
sudo -u splunk /opt/splunkforwarder/bin/splunk set deploy-poll \
  192.168.248.203:8089 -auth admin:adminuser123!
```

> **Note:** The `targetUri` does not require `https://` prefix — the UF defaults to SSL on port 8089 regardless of whether the scheme is specified. Extensive troubleshooting confirmed the UF was connecting successfully all along — the issue was dashboard visibility, not connectivity (see Known Issue below).

**Restart the UF after setting the deploy-poll:**

```bash
sudo systemctl restart SplunkForwarder
```

---

## Step 2 — Create the pait_all_deploymentclient App

This app is deployed to all Universal Forwarders via Agent Management to centrally manage which Agent Management server they point to. It ensures the UF configuration is version-controlled and can be updated centrally rather than manually on each forwarder.

**App structure:**
```
pait_all_deploymentclient/
    default/
        deploymentclient.conf
    metadata/
        default.meta
        local.meta
```

`default/deploymentclient.conf`:
```ini
[deployment-client]

[target-broker:deploymentServer]
targetUri = 192.168.248.203:8089
```

`metadata/default.meta`:
```
[]
access = read : [ * ], write : [ admin ]
```

**Copy to Agent Management deployment-apps directory on mgmt-1:**

```bash
sudo cp -r /tmp/pait_all_deploymentclient /opt/splunk/etc/deployment-apps/
sudo chown -R splunk:splunk /opt/splunk/etc/deployment-apps/pait_all_deploymentclient
```

---

## Step 3 — Create Server Class

A server class maps agents to apps. The `pait_linux_universal_forwarders` server class targets all Linux Universal Forwarders and assigns them the `pait_all_deploymentclient` app.

**Create via the Agent Management UI on mgmt-1:**

Navigate to **Settings → Agent Management → Server Classes**

- Server class name: `pait_linux_universal_forwarders`
- Add app: `pait_all_deploymentclient`
- Add client: uf-1 (by hostname or IP)

**Reload the deployment server after creating the server class:**

```bash
sudo -u splunk /opt/splunk/bin/splunk reload deploy-server
```

No restart required — the reload is a live operation.

**Force immediate phone home from uf-1 (optional):**

```bash
sudo -u splunk /opt/splunkforwarder/bin/splunk reload deploy-server
```

Otherwise the UF will pick up the server class on its next automatic phone home cycle (every 60 seconds by default).

---

## Known Issue — Agent Management Dashboard Shows No Clients

### Symptom

After bootstrapping the UF and confirming it is phoning home, the Agent Management dashboard on mgmt-1 shows no connected clients. The dashboard appears empty despite the UF actively connecting every 60 seconds.

### Root Cause

Starting with Splunk 9.2, Agent Management writes phone home telemetry to two dedicated internal indexes:

- `_dsphonehome` — phone home events from agents
- `_dsclient` — client registration and metadata

The Agent Management dashboards read exclusively from these indexes. Since mgmt-1 is configured to forward all internal logs to the indexer layer with `index = false` in `outputs.conf`, this telemetry data lands on the indexers — not locally on mgmt-1.

Because mgmt-1 is not configured as a search peer of the indexer cluster, it cannot search data on the indexers. The result is the dashboards show nothing even though the data exists and the agent is connected.

This can be confirmed by searching from any search head:

```splunk
index=_dsphonehome | head 20
```

If phone home events appear here but not in the Agent Management dashboard on mgmt-1, selective indexing is the fix.

### Fix — Selective Indexing on mgmt-1

Add `index = true` and `selectiveIndexing = true` to the `[indexAndForward]` stanza in mgmt-1's `outputs.conf`. With selective indexing enabled, Splunk indexes data destined for internal indexes (like `_dsphonehome` and `_dsclient`) locally on mgmt-1 while still forwarding everything else to the indexers.

**Updated `pait_cluster_forwarder_outputs/default/outputs.conf` on mgmt-1:**

```ini
[indexAndForward]
index = true
selectiveIndexing = true

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
pass4SymmKey = <encrypted_indexer_discovery_secret>
manager_uri = https://192.168.248.204:8089
```

> **Important:** The `pait_cluster_forwarder_outputs` app is deployed generically across all non-indexing nodes. The selective indexing settings (`index = true`, `selectiveIndexing = true`) are specific to the Agent Management node (mgmt-1). All other nodes should retain `index = false`. Consider creating a dedicated `pait_agent_management_outputs` app for mgmt-1 in a future improvement to avoid this distinction being handled manually.

**Restart Splunk on mgmt-1 after updating:**

```bash
sudo systemctl restart Splunkd
```

After restart the Agent Management dashboard will populate with connected clients within one phone home cycle.

---

## Verification

### Confirm agent is connected — from search head

```splunk
index=_dsphonehome | stats latest(_time) as lastPhoneHome by data.clientId | convert ctime(lastPhoneHome)
```

### Confirm agent is visible in dashboard

Navigate to mgmt-1 → **Settings → Agent Management → Clients**

uf-1 should appear with:
- Status: Connected
- Last phone home: within the last 60 seconds
- Server class: `pait_linux_universal_forwarders`
- Apps: `pait_all_deploymentclient`

### Confirm app deployed to UF

On uf-1:

```bash
ls /opt/splunkforwarder/etc/apps/ | grep pait
```

`pait_all_deploymentclient` should be present.

---

## Future Improvement

The current setup uses a single `pait_cluster_forwarder_outputs` app across all non-indexing nodes with a manual selective indexing override on mgmt-1. A cleaner approach would be:

- Keep `pait_cluster_forwarder_outputs` with `index = false` for all nodes
- Create a dedicated `pait_agent_management_outputs` app for mgmt-1 with `index = true` and `selectiveIndexing = true`
- Deploy `pait_agent_management_outputs` only to mgmt-1

This is tracked in `docs/issues-and-improvements.md`.

---

## Notes

- Agent Management does not require explicit activation — any Splunk Enterprise instance assumes the role as soon as agents phone home to it
- The `reload deploy-server` command applies server class changes live without requiring a Splunk restart
- The UF phones home every 60 seconds by default — changes to server classes are picked up automatically within one phone home cycle
- The `_dsphonehome` and `_dsclient` indexes were introduced in Splunk 9.2 — environments upgrading from older versions need to account for selective indexing on the Agent Management node
- Selective indexing causes data to be indexed both locally on mgmt-1 AND forwarded to the indexers — a small amount of data duplication for the `_dsphonehome` and `_dsclient` indexes, which is acceptable