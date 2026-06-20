# OTel Collector: Prometheus Bridge to Elastic, and EDOT Exploration

**Date:** 2026-06-14
**Node(s) involved:** obs (otelcol-contrib, Prometheus, Grafana, node_exporter, Jaeger v2), elastic (192.168.248.210)

## Goal for this session

Finish configuring `otelcol-contrib` on obs (left mid-debug from a prior session) to scrape
the lab's existing Prometheus `node_exporter` targets and forward those metrics to
Elasticsearch, then evaluate whether the result is useful.

## 1. Resolved the startup failure (carried over from last session)

`otelcol-contrib` v0.154.0 was crash-looping with:

```
Error: failed to create meter provider: binding address 127.0.0.1:8888 for
Prometheus exporter: listen tcp 127.0.0.1:8888: bind: address already in use
```

**Root cause:** Jaeger (also an OTel Collector framework binary) was already bound to
`127.0.0.1:8888` for its own self-telemetry. `otelcol-contrib` defaults to the same port
for its self-monitoring metrics. Confirmed via `sudo ss -tlnp | grep 8888`.

**Fix:** override the collector's self-telemetry metrics address to `127.0.0.1:8889`.

## 2. Elasticsearch API key

Created via Kibana Dev Tools, scoped for current and future (traces/logs) use:

```json
POST /_security/api_key
{
  "name": "otelcol-contrib",
  "role_descriptors": {
    "otel_writer": {
      "cluster": ["monitor"],
      "index": [
        {
          "names": ["metrics-*", "traces-*", "logs-*"],
          "privileges": ["create_doc", "auto_configure"]
        }
      ]
    }
  }
}
```

The encoded key is passed to the collector via an environment variable (see below),
never written into the config file directly.

## 3. Final otelcol-contrib config (metrics bridge)

Node exporter targets reused as-is from the existing `prometheus.yml` (port 9101 on all
9 nodes — port 9100 collides with Splunk's indexer replication port, documented in an
earlier session).

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
receivers:
  prometheus/node_exporter:
    config:
      global:
        scrape_interval: 15s
        scrape_timeout: 10s
      scrape_configs:
        - job_name: node_exporter
          static_configs:
            - targets:
                - '192.168.248.203:9101'
                - '192.168.248.204:9101'
                - '192.168.248.205:9101'
                - '192.168.248.206:9101'
                - '192.168.248.207:9101'
                - '192.168.248.208:9101'
                - '192.168.248.209:9101'
                - '192.168.248.210:9101'
                - '192.168.248.212:9101'
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  resource/lab:
    attributes:
      - key: lab.name
        value: PlayAroundIT-observability-lab
        action: upsert
      - key: deployment.environment
        value: homelab
        action: upsert
      - key: telemetry.source
        value: otelcol-contrib
        action: upsert
  batch:
    timeout: 5s
    send_batch_size: 8192
exporters:
  otlp_http/elasticsearch:
    endpoint: https://192.168.248.210:9200/_otlp
    headers:
      Authorization: "ApiKey ${env:ELASTIC_API_KEY}"
    tls:
      ca_file: /etc/metricbeat/certs/http_ca.crt
    compression: gzip
    sending_queue:
      enabled: true
      sizer: bytes
      queue_size: 50000000
      block_on_overflow: true
      batch:
        flush_timeout: 1s
        min_size: 1000000
        max_size: 4000000
  debug:
    verbosity: basic
service:
  extensions:
    - health_check
  telemetry:
    logs:
      level: info
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: 127.0.0.1
                port: 8889
  pipelines:
    metrics/node_exporter_to_elastic:
      receivers:
        - prometheus/node_exporter
      processors:
        - memory_limiter
        - resource/lab
        - batch
      exporters:
        - otlp_http/elasticsearch
        - debug
```

### Two corrections made along the way

- **Exporter naming:** `otlphttp` is now a *deprecated alias*. The current component
  name is `otlp_http` (confirmed against the upstream
  `opentelemetry-collector` README). Keep using `otlp_http` going forward.
- **Endpoint typo:** the Elasticsearch native OTLP ingest endpoint is
  `https://192.168.248.210:9200/_otlp` (a duplicated-digit typo of `92009200` had to be
  fixed).

### Passing the API key via systemd

`${env:ELASTIC_API_KEY}` requires the variable to exist in the collector's *process*
environment, not just the shell. Set via a systemd drop-in:

```bash
sudo systemctl edit otelcol-contrib
```

```ini
[Service]
Environment="ELASTIC_API_KEY=<encoded id:api_key>"
```

then `sudo systemctl daemon-reload && sudo systemctl restart otelcol-contrib`.

**systemd layering note:** `/lib/systemd/system/` (= `/usr/lib/...` under usrmerge)
holds package-installed (vendor) unit files — don't edit these directly. `systemctl
edit <unit>` creates a drop-in override at
`/etc/systemd/system/<unit>.service.d/override.conf`, opened with a fully-commented
copy of the original unit as reference — only the (initially empty) area above that
comment block is what actually gets written. `systemctl cat <unit>` shows the merged
result of the vendor unit + any drop-ins, which is the way to verify an override took
effect.

## 4. Result

Confirmed working end to end: `node_exporter` (9 targets, port 9101) → `otelcol-contrib`
`prometheus` receiver → `otlp_http/elasticsearch` exporter → Elasticsearch native OTLP
ingest → visible in Kibana's metrics data view.

## 5. Kibana visualization findings

- No pre-built dashboards exist for raw Prometheus/`node_exporter` metric names ingested
  this way. Kibana's Observability "Hosts"/Infrastructure views expect either OTel
  semantic-convention host metrics (`hostmetrics` receiver) or ECS-mapped fields
  (Metricbeat, or the `elasticinframetrics` processor — see below), not raw
  `node_*` metric names.
- The field identifying which node a given sample came from is `service.instance.id`
  (the scrape target, e.g. `192.168.248.203:9101`) and `service.name` (the job name,
  `node_exporter`) — not `host.name`.
- The standard path for custom visualization is Lens + Dashboards, building panels
  per metric field and splitting by `service.instance.id`.
- **Notable recent development:** Elastic announced native PromQL support in Kibana
  (April 2026, tech preview) — a `PROMQL` source command in ES|QL that runs PromQL
  expressions directly against `metrics-*` indices, including OTel-ingested data.
  Worth checking whether this is available in our Kibana 9.4.x build — if so, it could
  let us reuse PromQL expressions from Grafana dashboards directly in Kibana.

## 6. Decision: tear down the Prometheus→Elastic pipeline

**Conclusion:** this was a valid proof-of-concept for "OTel Collector as a bridge from
an existing Prometheus setup into Elastic" — a real pattern for teams migrating from
Prometheus/Grafana to Elastic Observability without re-instrumenting everything. It
works.

**However**, it doesn't add net-new value to *this* lab: Metricbeat already provides
host metrics in Elastic, and the redundancy argument generalizes — any second
collector gathering the same OS-level host metrics for the same hosts just duplicates
data feeding the same kind of views.

**Action taken:** removed the `prometheus/node_exporter` receiver and
`otlp_http/elasticsearch` pipeline from the otelcol-contrib config on obs.
`otelcol-contrib` stopped.

**Retained value (skills/patterns, independent of the data's fate):** writing
receivers/processors/exporters from scratch, the `memory_limiter` + `resource`
processor ordering pattern, OTLP HTTP export with TLS + API-key auth via a systemd
env var, and the port-conflict debugging workflow (journalctl → diagnose → fix →
verify). All of this carries directly into the traces work.

## 7. EDOT (Elastic Distribution of OpenTelemetry) research

Investigated how Elastic actually gets OTel data to populate its built-in Observability
dashboards, since the generic OTLP ingest path above doesn't do any field mapping.

- The `elasticinframetrics` processor — which maps `hostmetrics` receiver output into
  **ECS-compatible** fields so Kibana's Infrastructure dashboards recognize it — is
  **EDOT-specific**, not present in `otelcol-contrib`.
- Elastic positions EDOT / OTel-native ingestion as their recommended path, independent
  of Fleet.
- Walked through Kibana's **Add Data → Host → OpenTelemetry** quickstart. Key finding:
  the download is the **standard `elastic-agent` tarball** — the quickstart just has you
  run the `otelcol` binary embedded inside it, using a sample config from
  `otel_samples/platformlogs_hostmetrics.yml`, instead of running Elastic Agent in its
  normal mode. Elastic Agent and EDOT Collector are converging into one artifact,
  selected by config/mode.
- That sample config has two pipelines:
  - `logs/platformlogs`: `filelog` receiver (`/var/log/*.log`) → `resourcedetection`
    processor → `elasticsearch/otel` exporter
  - `metrics/hostmetrics`: `hostmetrics` receiver → `elasticinframetrics` (+
    `attributes/dataset`, `resource/process`) → `elasticsearch/ecs` exporter
  - A `file_storage` extension backs the filelog receiver's offset tracking.
- **Security note:** the quickstart's setup script bakes the API key into `otel.yml` as
  a literal value via `sed`, rather than leaving it as `${env:...}`. If this config is
  ever adapted for the lab, revert to the env-var pattern before committing anything to
  the repo.
- Linux installs additionally require granting the `otelcol` binary the
  `CAP_DAC_READ_SEARCH` capability via `setcap` so the `filelog` receiver can read
  `/var/log/*`.

## 8. Decision: park EDOT/Agent-in-OTel-mode for later

Idea on the table: replace Metricbeat lab-wide with `elastic-agent install` configured
to run in OTel mode (via `elastic-agent.yml`), deployed via Ansible in place of the
existing Metricbeat playbook. Because `elasticinframetrics` maps to the *same* ECS
schema Metricbeat already uses, this would be a genuine like-for-like swap (same
dashboards, same schema, different collector) rather than the redundant-data problem
above — a real "Beats → OTel migration" exercise.

**Deferred** — revisit when specifically exploring Metricbeat alternatives.

## 9. Next session plan

1. Restart `otelcol-contrib` on obs with a config focused on **traces**, working with
   Jaeger v2 (already running on obs).
2. After traces: **logs** phase, candidate use case —
   - Ingest Splunk's `metrics.log` from idx-1/idx-2 (queue metrics: `indexqueue`,
     `parsingqueue`, `aggqueue`, etc.) via an OTel `filelog` receiver.
   - Pair with the existing Ansible-based load-testing tooling to observe queue
     behavior under load, visualized in Elastic and/or Grafana.
   - Open question to scope next time: structured *logs* (filelog + parsing operators,
     queryable in Discover/Lens) vs. converting these into time-series *metrics* — these
     imply different OTel pipeline shapes and need their own design discussion.