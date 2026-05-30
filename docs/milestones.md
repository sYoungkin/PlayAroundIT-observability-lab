# Lab Build — Milestones & Progress

This document tracks the build progress of the PlayAroundIT Observability Lab. Each milestone represents a completed, validated phase of the lab buildout.

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