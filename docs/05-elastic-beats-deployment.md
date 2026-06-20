# Elastic Beats Deployment — Auditbeat & Filebeat

This document covers the deployment of Auditbeat and Filebeat on the Universal Forwarder node (uf-1) in the PlayAroundIT Observability Lab. These beats complement the existing Metricbeat deployment by adding audit event monitoring and log file shipping.

---

## Architecture

| Beat | Node | Purpose | Data Destination |
|---|---|---|---|
| Metricbeat | All nodes | System metrics — CPU, memory, disk, network | Elasticsearch |
| Auditbeat | uf-1 | Audit events, file integrity monitoring | Elasticsearch |
| Filebeat | uf-1 | nginx access and error logs | Elasticsearch |

All beats ship data to Elasticsearch on the elastic node using TLS with the shared CA certificate already present at `/etc/metricbeat/certs/http_ca.crt`.

---

## Why Beats Instead of Elastic Agent + Fleet

Elastic Agent with Fleet is the strategic direction for Elastic — it consolidates all beats into a single agent managed centrally from Kibana. However for this lab environment Fleet was not viable due to resource constraints:

- The elastic node (4GB RAM) could not sustain Elasticsearch, Kibana, and Fleet Server simultaneously — the agent's internal monitoring components caused `EOF` errors due to memory pressure
- Moving Fleet Server to mgmt-1 (1GB RAM) caused the same issue — the agent's monitoring components try to connect to localhost:9200 which doesn't exist on that node
- Individual beats are significantly lighter than Elastic Agent and run cleanly within the lab resource constraints

Elastic Agent + Fleet will be revisited when additional RAM is available. For now individual beats provide equivalent data collection with lower overhead.

**Key observation:** Elastic's pre-built dashboards and ingest pipelines for beats (particularly Auditbeat) are significantly more complete than equivalent Splunk tooling. The Splunk TA for Unix and Linux requires the separate Splunk Observability Cloud product for dashboards — Elastic provides them out of the box at no additional cost.

---

## Auditbeat

### Overview

Auditbeat communicates directly with the Linux kernel audit framework and ships structured audit events to Elasticsearch. It supports two modes:

- **unicast** — Auditbeat is the sole consumer of audit events. auditd must be stopped.
- **multicast** — Auditbeat receives a broadcast copy of audit events alongside auditd. Both can run simultaneously.

This lab uses **multicast** mode so auditd continues running and managing rules, while both Splunk (via `rlog.sh` scripted input) and Elastic (via Auditbeat) receive the audit events simultaneously.

### Installation

```bash
sudo apt-get install -y auditbeat
```

Auditbeat is available from the Elastic 9.x APT repository already configured on uf-1 for Metricbeat.

### Configuration

```bash
sudo vi /etc/auditbeat/auditbeat.yml
```

```yaml
auditbeat.modules:

- module: auditd
  socket_type: multicast
  resolve_ids: true
  failure_mode: silent
  backlog_limit: 8192
  rate_limit: 0
  include_raw_message: false
  include_warnings: false

- module: file_integrity
  paths:
    - /bin
    - /usr/bin
    - /sbin
    - /usr/sbin
    - /etc

output.elasticsearch:
  hosts: ["https://192.168.248.194:9200"]
  username: "elastic"
  password: "adminuser123!"
  ssl.certificate_authorities:
    - "/etc/metricbeat/certs/http_ca.crt"

setup.kibana:
  host: "http://192.168.248.194:5601"
  username: "elastic"
  password: "adminuser123!"

logging.level: warning
logging.to_files: true
logging.files:
  path: /var/log/auditbeat
  name: auditbeat
  keepfiles: 7
```

**Key configuration notes:**

- `socket_type: multicast` — allows Auditbeat and auditd to coexist. Required since auditd is already running and managing rules
- `resolve_ids: true` — resolves UID/GID values to usernames and group names
- `failure_mode: silent` — Auditbeat silently ignores errors rather than stopping. Appropriate for lab use
- `file_integrity` module watches critical system directories for unauthorized changes — generates events when files are created, modified, or deleted

### Copy CA Certificate

```bash
sudo mkdir -p /etc/auditbeat
sudo cp /etc/metricbeat/certs/http_ca.crt /etc/auditbeat/http_ca.crt
```

### Setup and Start

```bash
# Load dashboards and index templates into Kibana/Elasticsearch
sudo auditbeat setup -e

# Test connectivity to Elasticsearch
sudo auditbeat test output

# Enable and start
sudo systemctl enable auditbeat
sudo systemctl start auditbeat
sudo systemctl status auditbeat
```

### Verification

Confirm data is flowing in Kibana Discover:

```
event.module: auditd
```

Confirm file integrity events:

```
event.module: file_integrity
```

**Key fields in auditd events:**
- `event.action` — what happened (e.g. executed, opened-file, changed-login-id)
- `event.category` — authentication, process, file, network
- `process.name` — process that triggered the event
- `user.name` — user associated with the event
- `auditd.data.proctitle` — decoded command line

Navigate to **Kibana → Dashboards** and search "Auditbeat" for pre-built dashboards including:
- Auditbeat Overview
- Auditbeat File Integrity
- Auditbeat Auditd

### auditd Rules

Custom audit rules are defined in `/etc/audit/rules.d/99-lab-rules.rules` on uf-1. These generate rich audit telemetry including:

- All program executions (`execve` syscalls)
- Privilege escalation attempts
- sudo usage
- User and group management
- Authentication events
- Network connections (`connect`, `bind` syscalls)
- File permission and ownership changes
- Kernel module loading
- SSH configuration changes
- Cron modifications
- System startup changes

Load rules after modification:

```bash
sudo augenrules --load
sudo auditctl -l | head -30
```

---

## Filebeat

### Overview

Filebeat ships log files to Elasticsearch. The nginx module provides automatic log parsing via Elasticsearch ingest pipelines and pre-built Kibana dashboards for nginx access and error logs.

### Installation

```bash
sudo apt-get install -y filebeat
```

### Configuration

```bash
sudo vi /etc/filebeat/filebeat.yml
```

```yaml
filebeat.config.modules:
  path: ${path.config}/modules.d/*.yml
  reload.enabled: false

output.elasticsearch:
  hosts: ["https://192.168.248.194:9200"]
  username: "elastic"
  password: "adminuser123!"
  ssl.certificate_authorities:
    - "/etc/metricbeat/certs/http_ca.crt"

setup.kibana:
  host: "http://192.168.248.194:5601"
  username: "elastic"
  password: "adminuser123!"

logging.level: warning
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat
  keepfiles: 7
```

> **Important:** The `filebeat.config.modules` block is required. Without it `filebeat modules enable` returns `Error in modules manager: modules management requires 'filebeat.config.modules.path' setting`.

### Enable nginx Module

```bash
sudo filebeat modules enable nginx
```

### Configure nginx Module

```bash
sudo vi /etc/filebeat/modules.d/nginx.yml
```

```yaml
- module: nginx
  access:
    enabled: true
    var.paths: ["/var/log/nginx/access.log*"]
  error:
    enabled: true
    var.paths: ["/var/log/nginx/error.log*"]
```

### Setup and Start

```bash
# Load dashboards and ingest pipelines
sudo filebeat setup -e

# Test connectivity
sudo filebeat test output

# Enable and start
sudo systemctl enable filebeat
sudo systemctl start filebeat
sudo systemctl status filebeat
```

### Verification

Confirm data is flowing in Kibana Discover:

```
event.module: nginx
```

Generate test traffic through the nginx load balancer:

```bash
# From your Windows machine browser
http://playaroundit-shc:8000
```

Each request will appear as an access log event in Elasticsearch.

**Key fields in nginx access events:**
- `http.request.method` — GET, POST etc.
- `http.response.status_code` — 200, 301, 404 etc.
- `url.path` — requested URL path
- `source.ip` — client IP address
- `http.response.body.bytes` — response size

Navigate to **Kibana → Dashboards** and search "Filebeat nginx" for pre-built dashboards including:
- Filebeat nginx Overview
- Response codes over time
- Top requested URLs
- Client IP distribution

---

## Elastic Streams

Kibana's **Observability → Streams** feature (introduced in recent 9.x versions) provides visibility into all data streams including:

- **Data lifecycle** — ILM policy, rollover settings, retention
- **Data quality** — field mapping health, schema validation
- **Extraction refinement** — field extraction tuning
- **Schema view** — full field mapping for the data stream

This feature provides a significantly more complete data management experience compared to Splunk's index management UI. Notable for the ability to tune extractions and view schema without leaving the observability context.

---

## Summary — All Beats on uf-1

| Beat | Status | Data |
|---|---|---|
| Metricbeat | ✓ Running | System metrics — CPU, memory, disk IOPS, network, services |
| Auditbeat | ✓ Running | Audit events, file integrity |
| Filebeat | ✓ Running | nginx access logs, nginx error logs |

All three beats ship to Elasticsearch on the elastic node using TLS. Data is visible in:
- **Kibana → Observability → Infrastructure** — host metrics
- **Kibana → Dashboards** — pre-built dashboards per beat
- **Kibana → Observability → Streams** — data stream management
- **Kibana → Discover** — raw event search

---

## Troubleshooting

**`modules management requires 'filebeat.config.modules.path' setting`:**
Add the `filebeat.config.modules` block to `filebeat.yml` before running `filebeat modules enable`.

**Auditbeat conflicts with auditd:**
Ensure `socket_type: multicast` is set in the auditd module config. Without it Auditbeat attempts unicast mode and conflicts with the running auditd process.

**Connection refused to Elasticsearch:**
Verify the Elasticsearch host IP and port in the beat configuration. Confirm Elasticsearch is running: `systemctl status elasticsearch`. Test with: `curl -k -u elastic:adminuser123! https://192.168.248.194:9200`

**No data appearing after startup:**
Run the beat with `-e` flag to see output in terminal: `sudo auditbeat -e` or `sudo filebeat -e`. This shows real-time processing and any errors.

**Setup command takes a long time:**
Normal — setup loads dashboards, index templates, and ingest pipelines into Kibana and Elasticsearch. Can take 2-5 minutes. Do not interrupt.

---

## Notes

- All beats use the same CA certificate at `/etc/metricbeat/certs/http_ca.crt` — no need to copy it separately
- Beats are installed from the Elastic 9.x APT repository already configured for Metricbeat
- The nginx module uses Elasticsearch ingest pipelines for parsing — no manual grok patterns needed
- Auditbeat multicast mode means audit rules remain managed by auditd — both Splunk and Elastic receive the same audit events simultaneously
- When the 16GB RAM upgrade arrives, revisit Elastic Agent + Fleet as a replacement for individual beats
EOF