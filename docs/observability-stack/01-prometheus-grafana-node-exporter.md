# Prometheus & Grafana — Installation and Node Exporter Deployment

This document covers the installation of Prometheus and Grafana on the obs node, and the deployment of Prometheus Node Exporter across all lab nodes via Ansible. This corresponds to Phase 1, Phase 2, and Phase 5 of the observability stack roadmap.

---

## Architecture

| Component | Node | Port |
|---|---|---|
| Prometheus | obs | 9090 |
| Grafana | obs | 3000 |
| Node Exporter | All 9 nodes | 9101 |

---

## Prometheus Installation

Prometheus 3.x is not available via standard Ubuntu APT repositories at a current version, so it is installed from the official binary release.

### Download and Extract

```bash
cd /tmp
curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest \
  | grep "browser_download_url.*linux-amd64.tar.gz" \
  | cut -d '"' -f 4 \
  | wget -qi -

tar xzf prometheus-*.linux-amd64.tar.gz
cd prometheus-*.linux-amd64
```

### Install Binaries

```bash
sudo mv prometheus promtool /usr/local/bin/
sudo mkdir -p /etc/prometheus /var/lib/prometheus
```

> **Note:** Prometheus 3.x removed the `consoles` and `console_libraries` directories present in older versions. These are no longer included in the release tarball and do not need to be moved or referenced in the systemd service.

### Create Prometheus User

```bash
sudo useradd --no-create-home --shell /bin/false prometheus
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
```

### Base Configuration

```bash
sudo tee /etc/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node_exporter'
    static_configs:
      - targets:
          - '<elastic_ip>:9101'
          - '<obs_ip>:9101'
          - '<mgmt1_ip>:9101'
          - '<mgmt2_ip>:9101'
          - '<idx1_ip>:9101'
          - '<idx2_ip>:9101'
          - '<sh1_ip>:9101'
          - '<sh2_ip>:9101'
          - '<uf1_ip>:9101'
EOF

sudo chown prometheus:prometheus /etc/prometheus/prometheus.yml
```

### Systemd Service

```bash
sudo tee /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.enable-remote-write-receiver \
  --storage.tsdb.retention.time=3d \
  --storage.tsdb.retention.size=3GB

[Install]
WantedBy=multi-user.target
EOF
```

**Flag notes:**
- `--web.enable-remote-write-receiver` — required for future OTel Collector integration (Phase 4) to push metrics via remote write
- `--storage.tsdb.retention.time=3d` — data older than 3 days is removed
- `--storage.tsdb.retention.size=3GB` — hard cap regardless of time, whichever limit is hit first triggers cleanup

### Enable and Start

```bash
sudo systemctl daemon-reload
sudo systemctl enable prometheus
sudo systemctl start prometheus
sudo systemctl status prometheus --no-pager
```

### Verify

```bash
curl -s http://localhost:9090/-/healthy
# Expected: Prometheus Server is Healthy.

curl -s http://localhost:9090/api/v1/status/flags | grep retention
# Confirms retention flags are active
```

Access UI: `http://<obs_ip>:9090`

---

## Grafana Installation

Grafana is installed via the official APT repository.

### Add Repository

```bash
sudo apt-get install -y apt-transport-https software-properties-common
sudo mkdir -p /etc/apt/keyrings/

wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null

echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
```

### Install

```bash
sudo apt-get update
sudo apt-get install -y grafana
```

### Enable and Start

```bash
sudo systemctl daemon-reload
sudo systemctl enable grafana-server
sudo systemctl start grafana-server
sudo systemctl status grafana-server --no-pager
```

### Access

```
http://<obs_ip>:3000
```

Default login: `admin` / `admin` — change on first login.

### Connect Prometheus Datasource

Connections → Data sources → Add data source → Prometheus

- Name: `Prometheus`
- URL: `http://localhost:9090`
- Save & test — should show green confirmation

---

## Node Exporter Deployment via Ansible

Node Exporter is deployed to all 9 lab nodes (8 Splunk nodes + obs itself) so that obs appears in Grafana dashboards alongside the rest of the infrastructure.

### Playbook: node_exporter_install.yml

```yaml
---
- name: Install Prometheus Node Exporter
  hosts: lab_all
  become: true

  vars:
    node_exporter_version: "1.8.2"

  tasks:

    - name: Create node_exporter user
      user:
        name: node_exporter
        shell: /bin/false
        system: true
        create_home: false

    - name: Download node_exporter
      get_url:
        url: "https://github.com/prometheus/node_exporter/releases/download/v{{ node_exporter_version }}/node_exporter-{{ node_exporter_version }}.linux-amd64.tar.gz"
        dest: /tmp/node_exporter.tar.gz

    - name: Extract node_exporter
      unarchive:
        src: /tmp/node_exporter.tar.gz
        dest: /tmp/
        remote_src: true

    - name: Install node_exporter binary
      copy:
        src: "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64/node_exporter"
        dest: /usr/local/bin/node_exporter
        owner: node_exporter
        group: node_exporter
        mode: '0755'
        remote_src: true

    - name: Create systemd service
      copy:
        dest: /etc/systemd/system/node_exporter.service
        content: |
          [Unit]
          Description=Prometheus Node Exporter
          Wants=network-online.target
          After=network-online.target

          [Service]
          User=node_exporter
          Group=node_exporter
          Type=simple
          ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9101

          [Install]
          WantedBy=multi-user.target

    - name: Enable and start node_exporter
      systemd:
        name: node_exporter
        enabled: true
        state: started
        daemon_reload: true

    - name: Clean up downloaded files
      file:
        path: "{{ item }}"
        state: absent
      loop:
        - /tmp/node_exporter.tar.gz
        - "/tmp/node_exporter-{{ node_exporter_version }}.linux-amd64"
```

### Run

```bash
cd /etc/ansible
ansible-playbook playbooks/node_exporter_install.yml
```

---

## Critical Issue — Port 9100 Collision with Splunk Replication Port

### Symptom

After deploying node_exporter on the default port `9100`, Prometheus showed all targets `UP` except idx-1 and idx-2, which showed `DOWN` with errors like:

```
Error scraping target: Get "http://192.168.248.206:9100/metrics":
net/http: HTTP/1.x transport connection broken: malformed HTTP response
"\x00\x00\x00\xdc\x00\x00\x00\x06\x00\x00\x00\x05_raw..."
```

The garbled response contained Splunk internal protocol fragments — `_raw`, `_meta`, `_time`.

### Root Cause

Splunk's indexer cluster uses **port 9100 for bucket replication** between peers (`[replication_port://9100]` in `server.conf`). This is the exact same default port as Prometheus Node Exporter. On idx-1 and idx-2, port 9100 was already bound by Splunk — node_exporter could not bind correctly, and Prometheus's scrape requests were colliding with Splunk's replication protocol on that port.

### Fix

Changed Node Exporter to listen on port **9101** across all nodes via `--web.listen-address=:9101` in the systemd service, and updated `prometheus.yml` scrape targets accordingly.

### Lesson Learned

When integrating new tooling into an existing Splunk environment, always check for port conflicts with Splunk's internal ports — particularly:
- `8089` — management port
- `8000` — Splunk Web
- `9997` — receiving port
- `9100` — indexer cluster replication port
- `8191` — KV store

---

## Restart Required After Config Changes

After updating the `node_exporter.service` file via the Ansible playbook and re-running it, the service was **not automatically restarted** — Ansible's `enabled: true, state: started` only starts a stopped service, it does not restart an already-running one with a changed config.

**Fix — explicit restart after any systemd unit file change:**

```bash
ansible lab_all -m systemd \
  -a "name=node_exporter state=restarted" \
  --become
```

Verify the new port is active:

```bash
ansible lab_all -m command \
  -a "ss -tlnp | grep 9101" \
  --become
```

---

## Grafana Dashboard

Imported community dashboard **ID 1860 — "Node Exporter Full"** via Dashboards → New → Import. Provides comprehensive CPU, memory, disk, and network panels with a per-host selector dropdown.

### Stale Instance Labels

After changing Node Exporter from port 9100 to 9101, the Grafana host dropdown showed both `:9100` (stale, no longer scraped) and `:9101` (current) entries for the same host. This is expected — Prometheus retains historical label values for all series it has ever seen until they age out via retention.

With `--storage.tsdb.retention.time=3d` configured, the stale `:9100` entries will disappear from dropdowns automatically within 3 days.

---

## Verification Checklist

```bash
# Prometheus healthy
curl -s http://localhost:9090/-/healthy

# All targets UP — check in UI under Status → Targets
# Expected: 9/9 node_exporter UP, 1/1 prometheus UP

# Retention flags active
curl -s http://localhost:9090/api/v1/status/flags | grep retention

# Grafana running
systemctl status grafana-server --no-pager
```

---

## Notes

- Prometheus UTC timestamps vs local browser time (CEST = UTC+2) can make data appear stale when it is not — always check the timezone when troubleshooting "no data" issues
- Always restart (not just enable/start) a systemd service after any unit file change via Ansible
- Port 9100 is reserved by Splunk for indexer cluster replication — Node Exporter uses 9101 in this lab
- Retention is now consistent across the stack — Splunk (7 days), Elasticsearch (7 days via ILM), Prometheus (3 days / 3GB)
- Next phase: Jaeger for distributed traces, followed by OTel Collector for the fan-out pipeline