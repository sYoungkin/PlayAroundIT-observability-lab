# Lab Build — Milestones & Progress

This document tracks the build progress of the PlayAroundIT Observability Lab. Each milestone represents a completed, validated phase of the lab buildout.

## Milestone 3 — Full Environment Build & Splunk Cluster Configuration

**Completed:** 2026-06-05

### What Was Built

#### Infrastructure
- All 6 Splunk VMs provisioned and running
- Splunk 10.4 installed on all nodes via automated install script
- Splunk package cache implemented — installer copied from host via Vagrant synced folder, eliminating repeated downloads on reprovision
- NTP confirmed active on all nodes via `systemd-timesyncd` and VMware Tools clock synchronization

#### Splunk Secret Synchronization
- Two separate secrets generated and distributed — one per tier
- Search head tier secret shared across mgmt-1, sh-1, sh-2
- Indexer tier secret shared across mgmt-2, idx-1, idx-2
- Secrets generated with `/dev/urandom`, distributed via SCP directly between nodes
- Verified with `md5sum` across all nodes in each tier

#### Indexer Cluster
- Cluster Manager configured on mgmt-2 (`pait_cluster_manager_base`)
- Indexer discovery enabled on Cluster Manager with dedicated `pass4SymmKey`
- Two indexer peers bootstrapped and registered (`pait_cluster_indexer_base`)
- Configuration centralized in `manager-apps` after bootstrap
- Replication factor 2, search factor 2, single-site
- License Manager running on mgmt-2, both indexers reporting as license peers
- Splunk data directories created on indexers with volume-based storage:
  - `hot_tier` → `/opt/splunkdata/hot` (2GB)
  - `cold_tier` → `/opt/splunkdata/cold` (5GB)
  - `thawed` → `/opt/splunkdata/thawed`

#### Index Configuration
- `pait_all_indexes` deployed to indexer cluster — volume-based paths, 3 custom indexes
- `pait_all_search_indexes` deployed to search head cluster — `$SPLUNK_DB` variable paths for autocomplete without crashing search heads
- Indexes created: `linux_audit`, `linux_logs`, `nginx_access`
- Volume configuration confirmed working — hot buckets created under `/opt/splunkdata/hot/linux_audit/`

#### Search Head Cluster
- Search Head Deployer configured on mgmt-1
- Two SHC members initialized and bootstrapped
- Captain elected dynamically — sh-1 elected as initial captain
- `pait_cluster_search_base` deployed via deployer — search heads connected to indexer cluster
- License manager configured on all search heads

#### Internal Log Forwarding
- `pait_cluster_forwarder_outputs` deployed to all non-indexing nodes
- Indexer discovery used for dynamic indexer routing
- `index = false` on all non-indexing nodes — no local indexing
- `useACK = true` — indexer acknowledgement enabled
- mgmt-1 configured with selective indexing (`index = true`, `selectiveIndexing = true`) for Agent Management `_dsphonehome` and `_dsclient` indexes

#### Agent Management (Deployment Server)
- mgmt-1 confirmed as Agent Management server
- uf-1 bootstrapped as deployment client
- Server class `pait_linux_universal_forwarders` created
- Apps deployed to UF via Agent Management:
  - `pait_all_deploymentclient` — points UF to Agent Management
  - `pait_uf_outputs` — indexer discovery outputs for UF
  - `Splunk_TA_effective_configuration` — enables config visibility from UI
- Selective indexing configured on mgmt-1 for Agent Management dashboard visibility
- Filesystem permissions locked down on deployment-apps sensitive files

#### nginx Load Balancer
- nginx installed on uf-1
- Reverse proxy load balancing across sh-1 and sh-2 on port 8000
- `ip_hash` for session stickiness
- `proxy_redirect` configured to rewrite Location headers — prevents browser bypassing load balancer on 303 redirects
- `playaroundit-shc` hostname configured in Windows hosts file
- Access URL: `http://playaroundit-shc:8000`

#### Monitoring Console
- Configured on mgmt-2 in distributed mode
- All Splunk roles assigned — Cluster Manager, License Manager, Indexers, Search Heads, Deployment Server
- All components visible and healthy in dashboard

#### Splunk Add-on for Unix and Linux
- Deployed to indexer cluster (index-time extractions)
- Deployed to search head cluster (search-time extractions, CIM mapping)
- Deployed to UF via Agent Management with auditd scripted input enabled
- auditd scripted input uses `ausearch -i` for hex interpretation — ES compatible
- Data flowing into `linux_audit` index from uf-1

---

### Validated

| Component | Test | Result |
|---|---|---|
| Indexer cluster formation | Both peers Up in CM UI | ✓ |
| Replication factor met | CM status shows RF=2 satisfied | ✓ |
| Search head cluster | Captain elected, both members Up | ✓ |
| Distributed search | Search heads connected to indexer cluster | ✓ |
| License Manager | Both indexers and search heads reporting | ✓ |
| Internal log forwarding | `index=_internal host=mgmt-1` returns results on search heads | ✓ |
| Agent Management | uf-1 visible in dashboard, phone home confirmed | ✓ |
| Volume storage | Hot buckets present under `/opt/splunkdata/hot/linux_audit/` | ✓ |
| Index autocomplete | linux_audit, linux_logs, nginx_access visible in search bar | ✓ |
| nginx load balancer | `http://playaroundit-shc:8000` routes to search heads | ✓ |
| auditd data onboarding | `index=linux_audit sourcetype=auditd` returns decoded events | ✓ |
| proctitle decoding | `proctitle` field contains readable command lines | ✓ |
| Monitoring Console | All components visible in distributed mode | ✓ |

---

### Key Decisions & Notes

- **Two index apps required** — `pait_all_indexes` with volume references for indexers, `pait_all_search_indexes` with `$SPLUNK_DB` variables for search heads. Deploying the volume-based app to search heads crashes Splunk on startup.
- **Selective indexing on mgmt-1** — required from Splunk 9.2+ for Agent Management dashboards to show connected clients. Without it `_dsphonehome` data lands on indexers and mgmt-1 cannot see it.
- **nginx on uf-1 not mgmt-1** — avoids port 8000 conflict with Splunk Web on mgmt-1. The UF node has no Splunk Web making it the ideal host.
- **Source Types UI hidden in SHC** — expected behavior in 10.4. Use REST API instead: `| rest splunk_server=local /services/saved/sourcetypes`
- **auditd scripted input preferred over file monitor** — `ausearch -i` decodes hex `proctitle` values required for Splunk ES and Threat Research use cases.
- **Agent Management dashboard** — the forwarder was always connected but invisible because mgmt-1 lacked visibility into `_dsphonehome` index data on the indexers.

--- 

## Milestone 2 — Observability & Automation Foundation

**Completed:** 2026-05-31

### What Was Built

#### Ansible Control Node (elastic)
- Ansible installed and upgraded to latest version via pip3
- Private key at `/root/.ssh/ansible_lab`
- Public key injected into all lab VMs via Vagrant global provisioner
- `ansible.cfg` configured with `host_key_checking = False`, hardcoded inventory path, vault password file reference
- Inventory structured with named groups: `elastic_node`, `splunk_management`, `splunk_indexers`, `splunk_search_heads`, `splunk_forwarders`, `splunk_all`, `lab_all`
- `group_vars/all/` subdirectory structure — required for Ansible to auto-load vault alongside plaintext vars
- Elastic node IP resolved dynamically via `ansible_default_ipv4.address` — no hardcoded IP in inventory or vars
- Vault encrypted with `ansible-vault` — never committed to repo, created manually post-provision

#### Metricbeat Ansible Playbook
- Play 1 — Gather facts from all hosts — required for dynamic elastic IP resolution
- Play 2 — Distribute Elasticsearch CA cert to all Splunk nodes via `slurp` module
- Play 3 — Install Metricbeat on all nodes from Elastic 9.x APT repo
- Play 4 — Deploy Metricbeat config via Jinja2 template with dynamic variable injection
- Play 5 — Enable `system`, `linux`, `beat-xpack` modules on all nodes
- Play 6 — Enable `elasticsearch-xpack` and `kibana-xpack` modules on elastic node only
- Play 7 — Run `metricbeat setup --index-management` on elastic node
- Playbook is fully idempotent — safe to re-run at any time

#### Jinja2 Template (`metricbeat.yml.j2`)
- Dynamic Elasticsearch host resolved at runtime from gathered facts
- SSL configured with CA cert path — differs between elastic node and Splunk nodes via `host_vars`
- Credentials injected from vault-backed group vars

#### group_vars Structure
- `ansible/inventory/group_vars/all/all.yml` — plaintext variables, committed to repo
- `ansible/inventory/group_vars/all/vault.yml` — encrypted secrets, never in repo, created manually post-provision
- `ansible/inventory/host_vars/elastic.yml` — overrides CA cert path for elastic node specifically

#### auditd on Universal Forwarder
- `auditd` and `audispd-plugins` installed via `splunk_uf_install.sh`
- `audit_readers` group created
- `splunk` user added to `audit_readers` group
- `log_group = audit_readers` configured in `/etc/audit/auditd.conf`
- auditd enabled and started automatically

---

### Validated

| Component | Test | Result |
|---|---|---|
| Elastic node provisioning | Full auto-install of Elasticsearch, Kibana, Ansible | ✓ |
| Ansible upgrade | pip3 install confirms current version post-provision | ✓ |
| SSH key distribution | Ansible ping to all nodes returns SUCCESS | ✓ |
| Ansible vault | Vault decryption and variable resolution confirmed | ✓ |
| Dynamic elastic IP | `elasticsearch_host` resolves to real IP via fact gathering | ✓ |
| CA cert distribution | `/etc/metricbeat/certs/http_ca.crt` present on all Splunk nodes | ✓ |
| Metricbeat on elastic node | system, linux, beat-xpack, elasticsearch-xpack, kibana-xpack modules running | ✓ |
| Metricbeat on mgmt-1 | system, linux, beat-xpack modules running, data shipping to Elasticsearch | ✓ |
| Metricbeat on uf-1 | system, linux, beat-xpack modules running, data shipping to Elasticsearch | ✓ |
| Elasticsearch indices | `metricbeat-*` indices present with documents | ✓ |
| Kibana Infrastructure | All nodes visible in Observability → Infrastructure dashboard | ✓ |
| auditd on uf-1 | Service running, audit_readers group created, splunk user member | ✓ |

---

### Key Decisions & Notes

- **Vault file location is critical** — must be at `inventory/group_vars/all/vault.yml` alongside `all.yml`. Placing it at the Ansible root (`/etc/ansible/group_vars/`) causes silent variable resolution failure.
- **elastic node uses `ansible_connection=local` only** — no `ansible_host` set. Setting `ansible_host=127.0.0.1` causes all other nodes to try to ship Metricbeat data to loopback. Real IP discovered via `ansible_default_ipv4.address` fact.
- **Fact gathering play is mandatory** — `hosts: lab_all, gather_facts: true` must be the first play in any playbook that references `hostvars['elastic']['ansible_default_ipv4']['address']`. Without it the variable is undefined at render time.
- **`metricbeat setup --dashboards` not used** — imports legacy Kibana 7 dashboard assets that fail with 500 errors on Kibana 9.x. Using `--index-management` instead for Elasticsearch assets. Kibana data view created manually post-deployment.
- **CA cert distribution via slurp module** — cleaner than fetch/copy chain. Reads cert content into memory as base64 on elastic node, writes directly to target nodes. No temp files.
- **Ansible 2.10.8 from Ubuntu APT repos** — too old and has group_vars resolution quirks. Upgraded via pip3 to current version as part of elastic install script.
- **`[elastic_node]` group name** — not `[elastic]` to avoid Ansible naming conflict between group name and hostname.

---

## Milestone 1 — Infrastructure Provisioning & Automation Foundation

**Completed:** 2026-05-30

### What Was Built

#### Vagrantfile
- 8 VMs provisioned on VMware Workstation using `generic/ubuntu2204`
- Global provider defaults: 1 vCPU, 1GB RAM per VM
- Elastic node exception: 2GB RAM
- Synced folders disabled across all VMs
- SSH key injection: public key distributed to all VMs via global provisioner
- Private key injected to elastic node at `/root/.ssh/ansible_lab`
- Ansible playbooks and config pushed to elastic node via file provisioner
- All Splunk nodes provisioned with `splunk_install.sh` or `splunk_uf_install.sh`
- Elastic node provisioned with `elastic_install.sh`

#### Scripts
- `scripts/splunk_install.sh` — Splunk Enterprise 10.4.0 installation
  - Creates `splunk` system user
  - Installs to `/opt/splunk`
  - Configures systemd boot-start
  - Sets admin password via `user-seed.conf`
  - Startup intentionally deferred for manual Splunk secret configuration
- `scripts/splunk_uf_install.sh` — Splunk Universal Forwarder 10.4.0 installation
  - Same pattern as Enterprise script
  - Installs to `/opt/splunkforwarder`
  - Startup intentionally deferred
- `scripts/elastic_install.sh` — Elasticsearch and Kibana installation
  - Installs from Elastic APT 9.x repository
  - Sets `elastic` superuser password via keystore bootstrap
  - Resets `kibana_system` password via API
  - Configures `kibana.yml` directly — enrollment token flow intentionally bypassed
  - Grants Kibana access to Elasticsearch certificates via group membership
  - Generates and sets `xpack.encryptedSavedObjects.encryptionKey`
  - Installs Ansible and creates Ansible directory structure
  - Starts Elasticsearch and Kibana automatically
- `scripts/lab_status.sh` — Dynamic VM status and IP summary
  - Discovers VMs dynamically from Vagrant — no static list
  - SSHes into running VMs to retrieve IP addresses
  - Prints formatted status table

#### Ansible Control Node
- Ansible installed on elastic node
- Private key at `/root/.ssh/ansible_lab`
- `ansible.cfg` configured with `host_key_checking = False`
- Inventory template at `/etc/ansible/inventory/hosts.ini`
- Playbooks directory at `/etc/ansible/playbooks/`

#### Inventory Structure
```
[elastic]
[splunk_management]
[splunk_indexers]
[splunk_search_heads]
[splunk_forwarders]
[splunk_all:children]     — all Splunk nodes
[lab_all:children]        — everything
```

#### Repository
- `PlayAroundIT-observability-lab` created on GitHub
- Structure: `/vagrant`, `/scripts`, `/ansible`, `/elastic`, `/splunk`, `/docs`
- `README.md` with architecture overview and status checklist
- `.gitignore` configured for `.vagrant/`, `.ssh/`, logs, Splunk packages

---

### Validated

| Component | Test | Result |
|---|---|---|
| Vagrant 8 VM provisioning | `vagrant up` — all 8 VMs created | ✓ |
| `lab_status.sh` | Dynamic IP discovery across all VMs | ✓ |
| Splunk Enterprise install | mgmt-1 provisioned, UI accessible, admin login confirmed | ✓ |
| Splunk UF install | uf-1 provisioned, service starts cleanly | ✓ |
| Elasticsearch | Cluster info returned via curl, auth confirmed | ✓ |
| Kibana | UI accessible at port 5601, login confirmed | ✓ |
| Ansible connectivity | `ansible all -m command -a "date"` returns from mgmt-1 | ✓ |

---

### Key Decisions & Notes

- **Splunk startup deferred intentionally** — Splunk secret must be synchronized across search head tier and indexer tier before first start. This is handled manually during the Splunk configuration phase.
- **Elastic enrollment token bypassed** — Kibana configured via direct `kibana.yml` settings. This is the correct approach for automated deployments and mirrors production practice.
- **Ansible on elastic node** — elastic node serves dual purpose as observability stack and Ansible control node. Natural fit since it already needs network access to all Splunk nodes for Metricbeat.
- **hosts.ini managed manually** — inventory is populated with actual IPs after provisioning using `lab_status.sh` output. The repo contains a template with placeholder IPs for documentation purposes.
- **SSH keys excluded from repo** — `.ssh/` directory is in `.gitignore`. Keys are generated once locally and injected via Vagrant provisioners.
- **2 search heads, consolidated management roles** — intentional deviation from Splunk production best practices to reduce resource overhead. Documented and understood.

---

## Milestone 2 — Splunk Cluster Configuration

**Status: Planned**

- Configure Splunk secrets across search head and indexer tiers
- Configure Cluster Manager and indexer cluster
- Configure Search Head Deployer and search head cluster
- Configure Deployment Server
- Configure License Manager and Monitoring Console
- Validate data flow from Universal Forwarder through indexers to search heads

---

## Milestone 3 — Metricbeat Deployment via Ansible

**Status: Planned**

- Develop Metricbeat Ansible playbook
- Deploy Metricbeat to all Splunk nodes via `ansible splunk_all`
- Configure Metricbeat to ship to Elasticsearch on elastic node
- Validate metrics appearing in Elasticsearch

---

## Milestone 4 — Kibana Observability Dashboards

**Status: Planned**

- Build Kibana dashboards for Splunk infrastructure metrics
- CPU, memory, disk, network, and process-level visibility
- Host-level overview across all Splunk nodes

---

## Milestone 5 — Prometheus & Grafana

**Status: Future**

- Deploy Prometheus on elastic node or dedicated VM
- Configure node exporters on Splunk nodes via Ansible
- Build Grafana dashboards
- Compare Elastic vs Prometheus/Grafana observability approaches