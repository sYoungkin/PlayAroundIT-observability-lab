# PlayAroundIT-observability-lab

> Home lab: distributed Splunk cluster + Elastic observability stack, provisioned with Vagrant on VMware Workstation

---

## Overview

This is a hands-on home lab for rebuilding and deepening practical skills in Splunk cluster administration and infrastructure observability. The lab provisions a multi-node distributed Splunk environment and uses an Elastic stack to monitor it from the outside — simulating how real observability works in production.

Everything here is real configuration, real tooling, and real troubleshooting. Not theory.

---

## Architecture

### Splunk Environment

| VM | Hostname | Role | RAM |
|---|---|---|---|
| Management Node 1 | mgmt-01 | Deployment Server, Search Head Deployer | 1GB |
| Management Node 2 | mgmt-02 | Cluster Manager, License Manager, Monitoring Console | 1GB |
| Search Head 1 | sh-01 | Search Head | 1GB |
| Search Head 2 | sh-02 | Search Head | 1GB |
| Indexer 1 | idx-01 | Indexer | 1GB |
| Indexer 2 | idx-02 | Indexer | 1GB |
| Universal Forwarder | uf-01 | Test data generation and forwarding | 1GB |

### Observability Environment

| VM | Hostname | Role | RAM |
|---|---|---|---|
| Elastic Stack | elastic-01 | Elasticsearch, Kibana, Metricbeat target | 2GB |

Metricbeat is deployed across all Splunk nodes, shipping system and service metrics into Elasticsearch. Kibana provides dashboards for infrastructure visibility across the Splunk environment.

**Total: 8 VMs — 9GB RAM committed**

---

## Stack

| Layer | Technology |
|---|---|
| Hypervisor | VMware Workstation |
| Provisioning | Vagrant + vagrant-vmware-desktop |
| Guest OS | Ubuntu 22.04 LTS (x86_64) |
| SIEM / Search | Splunk Enterprise |
| Forwarder | Splunk Universal Forwarder |
| Observability | Elasticsearch + Kibana + Metricbeat |
| Future | Prometheus + Grafana |

---

## Repository Structure

```
/vagrant        → Vagrantfile and provisioning shell scripts
/docs           → Architecture notes, decisions, lessons learned
/splunk         → Splunk config files, apps, inputs/outputs
/elastic        → Elasticsearch and Kibana configuration
/scripts        → Utility and automation scripts
README.md
```

---

## Objectives

### 1 — Splunk Cluster Administration
Rebuild hands-on familiarity with distributed Splunk deployments: configuring search heads, indexers, and management nodes; practicing deployment and configuration workflows; testing data flow from Universal Forwarder to Splunk; and troubleshooting real cluster behavior.

### 2 — Elastic Observability
Use Elastic as an observability platform for the Splunk lab. Deploy Metricbeat across Splunk nodes, collect CPU/memory/disk/network/process metrics, and build Kibana dashboards for infrastructure visibility.

### 3 — Prometheus and Grafana (Future)
Extend the lab into the Prometheus/Grafana ecosystem to compare metric collection models, learn exporters and scraping configuration, and build Grafana dashboards alongside the existing Elastic stack.

---

## Current Status

- [ ] Vagrantfile and provisioning scripts
- [ ] Splunk Enterprise installation and base configuration
- [ ] Cluster Manager and indexer cluster configuration
- [ ] Search Head configuration
- [ ] Deployment Server and Search Head Deployer configuration
- [ ] Universal Forwarder configured and forwarding test data
- [ ] Confirmed data flow into Splunk
- [ ] Elasticsearch and Kibana installed
- [ ] Metricbeat deployed across Splunk nodes
- [ ] Kibana dashboards for Splunk infrastructure metrics
- [ ] Prometheus and Grafana (future phase)

---

## Notes

- This lab intentionally deviates from Splunk production best practices in some areas (e.g. 2 search heads instead of the 3-node SHC minimum, consolidated management roles) to reduce resource overhead while still practicing the core configuration patterns.
- The focus is on configuration correctness, operational understanding, and observability — not production-grade resilience.

---

## Platform

Built and tested on Windows 10/11 desktop with VMware Workstation. Vagrant used for VM provisioning and reproducibility.
