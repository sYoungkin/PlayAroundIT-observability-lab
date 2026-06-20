# Jaeger v2 Setup & HotROD Trace Validation

This document covers the installation and configuration of Jaeger v2 on the obs node, and validation of the OTLP trace pipeline using the bundled HotROD demo application. This corresponds to Phase 3 of the observability stack roadmap.

---

## Architecture Note — Jaeger v2

Jaeger v2 is a major architectural shift from v1.x — the `jaeger` binary is itself built on the **OpenTelemetry Collector framework**. It includes core OTel Collector components (OTLP receiver, batch processor) plus a curated set of contrib components, plus Jaeger-specific components (`jaeger_storage` extension, `jaeger_query` extension/UI, `jaeger_storage_exporter`).

This means Jaeger's `config.yaml` looks structurally identical to a general-purpose OTel Collector config — `receivers`, `processors`, `extensions`, `exporters`, `service.pipelines`. However, the `jaeger` binary is a **curated distribution**, not the full `otelcol-contrib` build. It is treated in this lab as a **dedicated traces backend** (storage + query UI), kept conceptually and operationally separate from the standalone `otelcol-contrib` instance that will serve as the lab's general-purpose fan-out collector (Phase 4).

---

## Port Allocation on obs Node

| Port | Service | Notes |
|---|---|---|
| 3000 | Grafana | |
| 9090 | Prometheus | |
| 9101 | node_exporter | All 9 lab nodes |
| 16686 | Jaeger UI / Query API | Default port, not explicitly configured |
| 4319 | Jaeger OTLP gRPC receiver | Intentionally non-default |
| 4320 | Jaeger OTLP HTTP receiver | Intentionally non-default |
| 4317 / 4318 | *(reserved)* | For standalone otelcol-contrib — Phase 4 |
| 8080–8083 | HotROD services | frontend/customer/driver/route, only when running |

**Why 4319/4320 instead of the standard 4317/4318:** The standard OTLP ports are reserved for the future standalone OTel Collector, which will act as the lab's single "front door" — all telemetry sources point at 4317/4318, and the Collector fans out to Jaeger (on 4319/4320), Prometheus, and Elasticsearch. Configuring Jaeger's receiver explicitly in its YAML (rather than relying on v1.x environment variables) made this port reassignment straightforward.

---

## Installation

### Download and Extract

```bash
cd /tmp
curl -s https://api.github.com/repos/jaegertracing/jaeger/releases/latest \
  | grep "browser_download_url.*linux-amd64.tar.gz"
```

Download the main release tarball (not `jaeger-tools`, which contains separate utility binaries — index cleaners, schema tools — not needed here):

```bash
wget -q https://github.com/jaegertracing/jaeger/releases/download/v2.19.0/jaeger-2.19.0-linux-amd64.tar.gz
tar xzf jaeger-2.19.0-linux-amd64.tar.gz
cd jaeger-2.19.0-linux-amd64
ls
```

**Tarball contents:**
- `jaeger` (~126MB) — the v2 collector-based binary
- `example-hotrod` (~25MB) — the HotROD demo application, **bundled with the release**, no separate build required

> **Note:** Files in the tarball show ownership as `prometheus:prometheus`. This is a harmless coincidence — the tarball was built with files owned by numeric UID/GID `1001`, which happens to match the `prometheus` system user already present on this host from the Prometheus installation. Not related to Prometheus itself.

### Create User and Directories

```bash
sudo useradd --no-create-home --shell /bin/false jaeger

sudo mv jaeger /usr/local/bin/
sudo mv example-hotrod /usr/local/bin/

sudo chown jaeger:jaeger /usr/local/bin/jaeger /usr/local/bin/example-hotrod

sudo mkdir -p /etc/jaeger /var/lib/jaeger
sudo chown jaeger:jaeger /etc/jaeger /var/lib/jaeger
```

### Configuration

```bash
sudo tee /etc/jaeger/config.yaml << 'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4319
      http:
        endpoint: 0.0.0.0:4320

processors:
  batch:

extensions:
  jaeger_storage:
    backends:
      memstore:
        memory:
          max_traces: 100000
  jaeger_query:
    storage:
      traces: memstore

exporters:
  jaeger_storage_exporter:
    trace_storage: memstore

service:
  extensions: [jaeger_storage, jaeger_query]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [jaeger_storage_exporter]
EOF

sudo chown jaeger:jaeger /etc/jaeger/config.yaml
```

**Configuration notes:**

| Section | Purpose |
|---|---|
| `receivers.otlp` | Accepts traces via OTLP gRPC (4319) and HTTP (4320) |
| `processors.batch` | Batches spans before export — empty config uses sensible defaults |
| `extensions.jaeger_storage` | Defines storage backends; `memory` backend with up to 100,000 traces |
| `extensions.jaeger_query` | Provides the Query API and UI (port 16686, not explicitly set), reads from `memstore` |
| `exporters.jaeger_storage_exporter` | Writes received spans to the `memstore` backend |
| `service.pipelines.traces` | Wires receiver → batch processor → storage exporter |

**Storage choice:** `memory` backend means traces are lost on restart. This is consistent with the lab's short-retention philosophy (Splunk 7d, Elastic ILM 7d, Prometheus 3d). `badger` (embedded DB) is available as a persistent alternative if needed later.

### Systemd Service

```bash
sudo tee /etc/systemd/system/jaeger.service << 'EOF'
[Unit]
Description=Jaeger v2 (OTel Collector distribution)
Wants=network-online.target
After=network-online.target

[Service]
User=jaeger
Group=jaeger
Type=simple
ExecStart=/usr/local/bin/jaeger --config /etc/jaeger/config.yaml
WorkingDirectory=/var/lib/jaeger
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable jaeger
sudo systemctl start jaeger
sudo systemctl status jaeger --no-pager
```

### Verify

```bash
sudo ss -tlnp | grep -E "4319|4320|16686"
```

Access UI: `http://<obs_ip>:16686`

---

## Validation with HotROD

### Discovering HotROD's CLI

`example-hotrod --help` reveals the relevant flags:

```
-j, --jaeger-ui string      Address of Jaeger UI to create [find trace] links (default "http://localhost:16686")
-x, --otel-exporter string  OpenTelemetry exporter (otlp|stdout) (default "otlp")
```

No explicit OTLP endpoint flag — it follows standard OpenTelemetry SDK environment variables (`OTEL_EXPORTER_OTLP_ENDPOINT`).

### Running HotROD

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4320 /usr/local/bin/example-hotrod all
```

This starts all four HotROD services:

| Service | Port |
|---|---|
| frontend | 8080 |
| customer | 8081 |
| driver | 8082 |
| route | 8083 |

> **Important:** Use port **4320** (Jaeger's HTTP OTLP receiver), not 4319 (gRPC). See Troubleshooting below for why this matters.

### Generating and Viewing Traces

1. Open `http://<obs_ip>:8080` — HotROD's frontend UI ("request a ride" demo)
2. Click one of the location buttons — fires a request spanning frontend → customer → driver → route
3. Open `http://<obs_ip>:16686` (Jaeger UI) → select `frontend` from the service dropdown → click **Find Traces**

A multi-span distributed trace across all four services should appear.

---

## Troubleshooting

### Protocol Mismatch — OTLP/HTTP Client to gRPC Receiver

**Symptom (in HotROD's output):**

```
traces export: Post "http://localhost:4319/v1/traces": readfrom tcp 127.0.0.1:42648->127.0.0.1:4319: write: connection reset by peer
traces export: Post "http://localhost:4319/v1/traces": net/http: HTTP/1.x transport connection broken: malformed HTTP response "\x00\x00\x06\x04\x00\x00\x00\x00\x00\x05\x00\x00@\x00"
```

**Root cause:**

The path `/v1/traces` is the signature of **OTLP/HTTP** — HotROD's `otlp` exporter defaulted to the HTTP protocol. However, port `4319` is configured as Jaeger's **gRPC** receiver. gRPC runs over HTTP/2 — when HotROD's HTTP/1.1 client connects, the gRPC server immediately sends an HTTP/2 connection preface (a SETTINGS frame) which the HTTP/1.1 client cannot parse.

The "malformed response" bytes decode exactly as an HTTP/2 frame header: `\x00\x00\x06` (length=6) `\x04` (type=4, SETTINGS) `\x00` (flags) `\x00\x00\x00\x00` (stream=0), followed by one settings parameter (`\x00\x05` = SETTINGS_MAX_FRAME_SIZE, `\x00\x00@\x00` = 16384, the HTTP/2 default).

**Fix:**

Point `OTEL_EXPORTER_OTLP_ENDPOINT` at port `4320` (Jaeger's HTTP receiver) instead of `4319`. OTLP/HTTP automatically appends `/v1/traces`, resulting in `http://localhost:4320/v1/traces` — which matches Jaeger's `http` protocol receiver.

**General lesson:** When an OTLP client defaults to HTTP but is pointed at a gRPC endpoint (or vice versa), the failure mode is a garbled/binary "malformed response" rather than a clean "wrong protocol" error. The `/v1/traces` (or `/v1/metrics`, `/v1/logs`) path in the request is the tell that the client is using OTLP/HTTP.

---

### Jaeger Self-Telemetry — Connection Refused on 4317

**Symptom (in `journalctl -u jaeger`):**

```
grpc: addrConn.createTransport failed to connect to {Addr: "127.0.0.1:4317", ...}
Err: connection error: desc = "transport: Error while dialing: dial tcp 127.0.0.1:4317: connect: connection refused"
{"resource": {"service.name": "jaeger", "service.version": "v2.19.0"}, "grpc_log": true}
```

**Analysis:**

The `service.name: jaeger` in the resource indicates this is Jaeger's **own OTel Collector framework self-telemetry** — not related to the HotROD trace data pipeline. The OTel Collector framework has built-in self-observability that, by default, attempts to export its own internal traces/metrics to the conventional default OTLP port `4317`. Nothing currently listens on 4317 (that's reserved for the future standalone otelcol-contrib).

**Status:** Currently benign — confirmed by the fact that HotROD traces flow correctly through the configured pipeline (receiver on 4320 → batch → memstore → query UI) despite this ongoing noise. Revisit once the standalone OTel Collector is running on 4317 — Jaeger's self-telemetry may then either connect successfully (which could be useful) or may need to be explicitly configured/disabled via a `service.telemetry` section if undesired.

---

### HotROD "Find Trace" Link Shows Blank Page

**Symptom:** Clicking "show trace" links inside the HotROD frontend UI leads to a blank page.

**Cause:** `--jaeger-ui` defaults to `http://localhost:16686`. Since HotROD runs on obs, "localhost" refers to obs itself — but the link is opened in a browser on a different machine, where `localhost:16686` doesn't exist.

**Fix (optional):** Pass `--jaeger-ui http://<obs_ip>:16686` when starting HotROD so generated links use the reachable IP. Alternatively, ignore HotROD's generated links entirely and navigate the Jaeger UI directly (select service, Find Traces).

---

## Verification Checklist

```bash
# Jaeger service running
sudo systemctl status jaeger --no-pager

# Ports bound
sudo ss -tlnp | grep -E "4319|4320|16686"

# Jaeger UI accessible
# http://<obs_ip>:16686

# Generate test trace
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4320 /usr/local/bin/example-hotrod all
# Click a ride request at http://<obs_ip>:8080
# Confirm trace appears in Jaeger UI under service "frontend"
```

---

## Notes for Repeatability

- `example-hotrod` is bundled in the main Jaeger release tarball — no separate download or build needed
- `jaeger-tools` tarball is not needed for this setup
- Ports 4317/4318 are intentionally left free for the standalone OTel Collector (Phase 4) — Jaeger uses 4319/4320
- `memory` storage backend means all trace data is lost on Jaeger restart — by design, consistent with lab-wide short retention
- The numeric UID/GID `1001` ownership on extracted files is cosmetic and specific to whatever system users happen to exist with that ID — not a meaningful signal
- When testing any OTLP client against this Jaeger instance, remember: gRPC → 4319, HTTP → 4320