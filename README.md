# PlayAroundIT-observability-lab

> Home lab: distributed Splunk cluster + Elastic and OpenTelemetry-based observability stack, provisioned with Vagrant on VMware Workstation

---

## Overview

This is a hands-on home lab for rebuilding and deepening practical skills in Splunk cluster administration and infrastructure observability. The lab provisions a multi-node distributed Splunk environment and observes it from the outside using two parallel observability stacks — Elastic (Elasticsearch/Kibana/Beats) and OpenTelemetry (otelcol-contrib, Prometheus, Grafana, Jaeger) — simulating how real observability works in production, including direct comparison between collection models.

Everything here is real configuration, real tooling, and real troubleshooting. Not theory.

---

## Architecture

### Splunk Environment

| VM | Hostname | Role |
|---|---|---|
| Management Node 1 | mgmt-1 | Deployment Server, Search Head Deployer |
| Management Node 2 | mgmt-2 | Cluster Manager, License Manager, Monitoring Console |
| Search Head 1 | sh-1 | Search Head |
| Search Head 2 | sh-2 | Search Head |
| Indexer 1 | idx-1 | Indexer |
| Indexer 2 | idx-2 | Indexer |
| Universal Forwarder | uf-1 | Universal Forwarder + nginx load balancer (fronting the Search Head Cluster) |

### Observability Environment

| VM | Hostname | Role |
|---|---|---|
| Elastic Stack | elastic | Elasticsearch, Kibana — Beats ingest target |
| Observability | obs | Prometheus, Grafana, Jaeger, otelcol-contrib — OTel-based stack |

**Total: 9 VMs**

Metricbeat, Filebeat, and Auditbeat are deployed across all nodes, shipping system, log, and audit data into Elasticsearch, with Kibana providing dashboards for infrastructure visibility. In parallel, `node_exporter` runs on all 9 nodes, scraped by Prometheus on `obs` and visualized in Grafana — giving a side-by-side comparison of the Beats and Prometheus/OTel collection models against the same infrastructure.

---

## Stack

| Layer | Technology |
|---|---|
| Hypervisor | VMware Workstation |
| Provisioning | Vagrant + vagrant-vmware-desktop |
| Guest OS | Ubuntu 22.04 LTS (x86_64) |
| Config management | Ansible (run from the `elastic` node) |
| SIEM / Search | Splunk Enterprise 10.x (clustered: indexer cluster, search head cluster, dedicated management roles) |
| Forwarder | Splunk Universal Forwarder |
| Observability (Elastic) | Elasticsearch 9.4.2 + Kibana + Metricbeat/Filebeat/Auditbeat |
| Observability (OTel) | Prometheus 3.x + Grafana + Jaeger v2 + otelcol-contrib v0.154.0 |
| Identity (planned) | SAML/SSO for the Splunk cluster |

### Host hardware

Built and tested on a Windows desktop: Intel Core i5-8400 (6 physical cores, no
hyperthreading), 40 GB RAM (mismatched configuration across three sticks), Samsung
980 PRO PCIe 4.0 NVMe. With 9 VMs sharing 6 physical cores, **CPU is the binding
constraint** for this lab — RAM and storage have comfortable headroom by comparison.
A full hardware-fundamentals deep dive (CPU, memory, storage/IO, networking,
virtualization, architecture) was completed early in this project and is kept as
reference material in Notion.

---

## Repository Structure

\`\`\`
/ansible        → Ansible playbooks and roles for infrastructure config management
/docs           → Architecture notes, decisions, lessons learned (numbered by build order)
/scripts        → Utility and automation scripts
/splunk/apps    → Custom Splunk apps (deployed via deployment server / cluster bundle / SH deployer)
/vagrant        → Vagrantfile and provisioning shell scripts
.gitignore
README.md
\`\`\`

\`docs/\` is organized with numbered filenames reflecting build order, with an
\`observability-stack/\` subfolder specifically for the OTel/Prometheus/Jaeger work.
Living reference material (milestones, open issues, IP reference, architecture
diagram) is kept unnumbered.

---

## Objectives

### 1 — Splunk Cluster Administration
Hands-on familiarity with distributed Splunk deployments: indexer clustering,
search head clustering, deployment server / SH deployer workflows, secret
synchronization, TA deployment, internal log forwarding, and an nginx load balancer
fronting the search head cluster. Ongoing work includes retention tuning and
SAML/SSO integration for the cluster (planned).

### 2 — Elastic Observability
Elasticsearch + Kibana as an observability platform for the Splunk lab and the
broader environment. Metricbeat, Filebeat, and Auditbeat deployed across all nodes;
Kibana dashboards for infrastructure visibility; ILM-based retention tuned for a
short-retention lab profile.

### 3 — Prometheus and Grafana
`node_exporter` on all 9 nodes, scraped by Prometheus on `obs`, visualized in
Grafana — run alongside the Elastic stack as a direct comparison of metric
collection models (pull-based scraping vs. shipped agents).

### 4 — OpenTelemetry
`otelcol-contrib` on `obs` as the OTel layer:
- **Traces:** Jaeger v2 deployed and validated end-to-end with the bundled
  HotRod example application; nginx-based tracing (real SHC load balancer traffic)
  planned next.
- **Metrics bridge POC:** a `prometheus` receiver → Elasticsearch OTLP exporter
  pipeline was built and validated as a working proof of concept for migrating a
  Prometheus-based shop onto Elastic, then deliberately torn down — redundant with
  existing Metricbeat coverage in this particular lab, though the pattern itself is
  documented as a reusable migration approach.
- **Splunk Enterprise receiver:** pulls Splunk Cluster Manager operational metrics
  (indexing pipeline queue ratios, scheduler stats, health) via the Splunk REST API
  into Prometheus/Grafana — notable for being entirely API-driven, meaning the same
  approach could in principle monitor Splunk Cloud, not just on-prem deployments.
  Currently piloted against a single node (`mgmt-2`); expansion to indexers and
  search heads, plus custom SPL-based queue metrics from `metrics.log`, are planned.

---

## Current Status

- [x] Vagrantfile and provisioning scripts
- [x] Splunk Enterprise installation and base configuration
- [x] Cluster Manager and indexer cluster configuration
- [x] Search Head Cluster configuration
- [x] Deployment Server and Search Head Deployer configuration
- [x] Universal Forwarder configured, with nginx load balancer fronting the SHC
- [x] Confirmed data flow into Splunk
- [x] Elasticsearch and Kibana installed
- [x] Metricbeat, Filebeat, and Auditbeat deployed across all nodes
- [x] Kibana dashboards for infrastructure metrics
- [x] Prometheus and Grafana deployed on a dedicated `obs` node
- [x] `node_exporter` deployed to all 9 nodes
- [x] Jaeger v2 deployed and validated (HotRod trace generation)
- [x] `otelcol-contrib` installed and operational
- [x] OTel metrics bridge to Elasticsearch built, validated, and retired (POC complete)
- [x] Splunk Enterprise receiver pilot (Cluster Manager metrics → Prometheus/Grafana)
- [ ] Splunk Enterprise receiver expanded to indexers and search heads
- [ ] Custom SPL-based `metrics.log` queue metrics via OTel
- [ ] nginx OTel tracing on the Universal Forwarder / load balancer node
- [ ] SAML/SSO for the Splunk cluster

---

## Notes

- This lab intentionally deviates from Splunk production best practices in some
  areas (e.g. 2 search heads instead of the 3-node SHC minimum, consolidated
  management roles) to reduce resource overhead while still practicing the core
  configuration patterns.
- The focus is on configuration correctness, operational understanding, and
  observability — not production-grade resilience.
- Where this lab uses local Splunk service accounts (e.g. for the OTel receiver),
  that's a pragmatic shortcut for the home lab; production guidance and planned
  follow-up work treats identity (SAML/LDAP) and authorization (locally-defined,
  centrally-distributed roles) as separate concerns.

---

## Platform

Built and tested on a Windows desktop with VMware Workstation. Vagrant used for VM
provisioning and reproducibility.