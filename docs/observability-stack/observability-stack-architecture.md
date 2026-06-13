# Observability Stack — Architecture & Roadmap

This document describes the full observability architecture for the PlayAroundIT Observability Lab, including the OpenTelemetry-based collection pipeline, storage backends, and visualization layers.

---

## Architecture Overview

The lab runs two parallel observability stacks receiving the same telemetry data simultaneously. This enables direct comparison between platforms across metrics, traces, and logs.

```
Lab nodes (9 total)
    │
    ├── Existing beats (Metricbeat, Auditbeat, Filebeat)
    │       └──→ Elasticsearch (elastic node)
    │
    └── OTel Agents / Exporters (future)
            │
            ▼
    OTel Collector (obs node)
            │
            ├──── Metrics ──────┬──→ Prometheus     (obs:9090)
            │                   └──→ Elasticsearch  (elastic:9200)
            │
            ├──── Traces ───────┬──→ Jaeger         (obs:14250)
            │                   └──→ Elasticsearch  (elastic:9200)
            │
            └──── Logs ─────────────→ Elasticsearch  (elastic:9200)

Visualization
    ├── Kibana      (elastic:5601)  → Elasticsearch datasource
    └── Grafana     (obs:3000)      → Prometheus + Jaeger + Elasticsearch
```

---

## Signal Coverage by Platform

| Signal | Kibana + Elastic | Grafana + Prometheus/Jaeger |
|---|---|---|
| Metrics | ✓ via OTel Collector | ✓ via Prometheus |
| Traces | ✓ via OTel Collector | ✓ via Jaeger |
| Logs | ✓ via OTel Collector + Beats | ✓ via Elastic datasource in Grafana |

Elasticsearch serves as the **universal backend** — all three signals land there. Prometheus and Jaeger are **specialist backends** for metrics and traces respectively, providing the comparison point against Elastic's unified approach.

---

## Components on obs Node

| Service | Purpose | Port |
|---|---|---|
| OTel Collector | Receives telemetry, fans out to backends | 4317 (gRPC), 4318 (HTTP) |
| Prometheus | Metrics storage and querying | 9090 |
| Jaeger | Distributed traces storage and UI | 16686 (UI), 14250 (OTLP) |
| Grafana | Unified visualization frontend | 3000 |

---

## OTel Collector Pipeline Design

The Collector uses a **fan-out** pipeline — each signal is received once and exported to multiple backends simultaneously. This is one of OTel's core architectural advantages over proprietary agents.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  prometheus:
    config:
      scrape_configs:
        - job_name: lab-nodes
          static_configs:
            - targets:
                - mgmt-1:9100
                - mgmt-2:9100
                - idx-1:9100
                - idx-2:9100
                - sh-1:9100
                - sh-2:9100
                - uf-1:9100
                - elastic:9100

exporters:
  # Metrics exporters
  prometheusremotewrite:
    endpoint: http://localhost:9090/api/v1/write
  otlphttp/elastic_metrics:
    endpoint: https://192.168.248.194:9200

  # Traces exporters
  otlp/jaeger:
    endpoint: localhost:14250
  otlphttp/elastic_traces:
    endpoint: https://192.168.248.194:9200

  # Logs exporter
  otlphttp/elastic_logs:
    endpoint: https://192.168.248.194:9200

service:
  pipelines:
    metrics:
      receivers: [otlp, prometheus]
      exporters: [prometheusremotewrite, otlphttp/elastic_metrics]
    traces:
      receivers: [otlp]
      exporters: [otlp/jaeger, otlphttp/elastic_traces]
    logs:
      receivers: [otlp]
      exporters: [otlphttp/elastic_logs]
```

---

## Grafana Datasources

Grafana serves as the unified visualization frontend for the OTel-based stack, connecting to all three backends:

| Datasource | Type | URL | Data |
|---|---|---|---|
| Prometheus | Prometheus | http://localhost:9090 | Metrics |
| Jaeger | Jaeger | http://localhost:16686 | Traces |
| Elasticsearch | Elasticsearch | https://192.168.248.194:9200 | Logs + Metrics + Traces |

---

## Existing Stack (Running)

The following components are already deployed and collecting data:

| Component | Node | Status | Data |
|---|---|---|---|
| Metricbeat | All 9 nodes | ✓ Running | System metrics → Elasticsearch |
| Auditbeat | uf-1 | ✓ Running | Audit events → Elasticsearch |
| Filebeat | uf-1 | ✓ Running | nginx logs → Elasticsearch |
| Kibana | elastic | ✓ Running | Visualization |
| Elasticsearch | elastic | ✓ Running | Storage |

---

## Implementation Roadmap

### Phase 1 — Prometheus (current)

- [x] Install Prometheus on obs node
- [x] Configure Prometheus for remote write
- [x] Verify Prometheus is scraping metrics
- [x] Connect Grafana to Prometheus datasource

### Phase 2 — Grafana

- [x] Install Grafana on obs node
- [x] Configure Prometheus datasource
- [x] Import node exporter dashboards
- [ ] Build custom lab infrastructure dashboard

### Phase 3 — Jaeger

- [ ] Install Jaeger on obs node
- [ ] Configure OTLP receiver
- [ ] Connect Grafana to Jaeger datasource
- [ ] Verify trace collection

### Phase 4 — OTel Collector

- [ ] Install OTel Collector on obs node
- [ ] Configure receivers — OTLP + Prometheus scrape
- [ ] Configure fan-out exporters — Prometheus + Jaeger + Elasticsearch
- [ ] Verify all three signals flowing to all backends

### Phase 5 — OTel Agents on Lab Nodes

- [ ] Deploy Prometheus node exporters via Ansible to all lab nodes
- [ ] Configure OTel Collector to scrape node exporters
- [ ] Verify all 9 nodes visible in Grafana
- [ ] Compare Grafana dashboards with Kibana Infrastructure inventory

### Phase 6 — Traces (Application Instrumentation)

- [ ] Instrument a simple application with OTel SDK
- [ ] Ship traces to OTel Collector
- [ ] Verify traces in Jaeger UI
- [ ] Verify traces in Kibana via Elastic APM

### Phase 7 — Comparison & Analysis

- [ ] Side-by-side dashboard comparison — Grafana vs Kibana
- [ ] Load test with stress-ng and observe in both platforms
- [ ] Document findings — where each platform excels
- [ ] OTel Collector managed via Splunk Agent Management (future)

---

## Key Design Decisions

**Why fan-out to both Elastic and Prometheus/Jaeger:**
The same raw telemetry flowing to both platforms enables direct apples-to-apples comparison of the analyst experience — query languages, dashboard quality, alerting, anomaly detection — without any difference in underlying data.

**Why Jaeger over Grafana Tempo:**
Jaeger is simpler to set up and is covered in the LFS148 OTel course. Tempo can be explored later once the trace collection fundamentals are understood.

**Why keep Beats running alongside OTel:**
Beats are proven, lightweight, and already working. Running OTel alongside rather than replacing Beats means nothing breaks during the learning process and both approaches can be directly compared.

**Why Elasticsearch as universal backend:**
Elastic 9.x natively supports OTLP ingest — metrics, traces, and logs can all be shipped via OTLP without additional configuration. This makes Elastic uniquely positioned as a single pane of glass alongside the specialist tools.

---

## Learning Path Integration

This architecture maps directly to the Linux Foundation LFS148 OpenTelemetry course:

| Course Topic | Lab Implementation |
|---|---|
| OTel signals (metrics, traces, logs) | All three flowing through Collector |
| OTel Collector pipeline | Receivers → Processors → Exporters |
| OTLP protocol | Used for all exports to backends |
| Instrumentation | Node exporters + future app instrumentation |
| Backends | Prometheus (metrics), Jaeger (traces), Elastic (all) |

---

## Notes

- The obs node runs at 2GB RAM — monitor memory usage as services are added
- All services on obs run without TLS internally — this is a lab environment
- OTel Collector connects to Elasticsearch using the existing CA cert from Metricbeat
- Prometheus remote write requires Prometheus 2.x+ with `--web.enable-remote-write-receiver` flag
- Jaeger supports native OTLP ingest from version 1.35+
EOF