# Splunk Enterprise Receiver: Cluster Manager Metrics Pilot

**Node(s) involved:** obs (otelcol-contrib), mgmt-2 (Cluster Manager / License Manager / Monitoring Console)
**otelcol-contrib version:** v0.154.0

## Goal

Pull Splunk Enterprise operational metrics — specifically indexing pipeline queue
fill ratios — into the existing observability stack via OTel, as an alternative to
relying solely on the Monitoring Console or manual `metrics.log` parsing. Piloted
against a single target (mgmt-2, as `cluster_master`) before considering wider rollout.

## Why this receiver

The `splunkenterprise` receiver (contrib repo:
`receiver/splunkenterprisereceiver`) is purely API-driven — it polls the Splunk REST
management API (port 8089) and optionally runs ad-hoc SPL searches. It does not run
on the Splunk nodes themselves and needs no filesystem access or Universal Forwarder.
This also means it could in principle monitor Splunk Cloud deployments (subject to
introspection endpoint availability there), which has direct relevance to managed
service / consulting contexts considering an OTel-based monitoring standardization.

The receiver also supports arbitrary custom SPL searches mapped to OTel metrics —
not used in this pilot, but the planned mechanism for pulling `metrics.log` queue
data (`group=queue`, `indexqueue`/`parsingqueue`/`aggqueue`/`typingqueue`) as
proper time series, instead of treating it as unstructured log text.

## 1. Service account (Splunk side)

Created directly via Splunk Web on mgmt-2 — a pragmatic shortcut for this proof of
concept, not the intended production pattern (see note below).

- Role: `otel_monitor`, created by inheriting the built-in `admin` role for now.
  Capabilities should be narrowed once we know exactly which endpoints the receiver
  calls; several Splunk introspection endpoints require `admin_all_objects`
  specifically since they expose internal operational data.
- User: `otel_svc`, assigned the `otel_monitor` role.

**Production note:** in a real deployment, this would invert — the `otel_svc`
identity would live in an external IdP (SAML/LDAP), with the `otel_monitor` role
distributed to Splunk nodes via standard config management and mapped to the IdP
group at login time, rather than a locally-provisioned account per instance. Setting
up SAML/SSO for the Splunk cluster is a planned follow-up project, independent of
the OTel work.

Verified directly before touching the collector config:

```bash
curl -k -u otel_svc:<password> "https://<mgmt-2-ip>:8089/services/server/introspection/queues?output_mode=json"
```

Run from the obs node specifically, since that's where the actual receiver call
originates from. A 200 with JSON content confirmed auth and capabilities were
sufficient.

## 2. otelcol-contrib configuration

### Receiver naming gotcha

The contrib README (tracking the `main` branch) states the receiver type was
renamed from `splunkenterprise` to `splunk_enterprise`. Our installed v0.154.0
does **not** include that rename — using `splunk_enterprise` fails with:

```
Error: failed to get config: cannot unmarshal the configuration: decoding failed due to the following error(s):
'receivers' unknown type: "splunk_enterprise" for id: "splunk_enterprise" (valid values: [...])
```

The valid-values list in that error is authoritative for the *installed* binary and
confirmed only `splunkenterprise` (no underscore) is recognized. Same category of
lesson as the earlier `otlphttp`/`otlp_http` rename: when contrib's README and the
installed binary disagree, trust the binary's own error output, not the docs — the
README tracks `main`, which can be ahead of any given release.

**Use `splunkenterprise` for this version.**

### Final working config additions

```yaml
extensions:
  basicauth/splunk_cm:
    client_auth:
      username: otel_svc
      password: ${env:SPLUNK_OTEL_PASSWORD}

receivers:
  splunkenterprise:
    collection_interval: 1m
    cluster_master:
      auth:
        authenticator: basicauth/splunk_cm
      endpoint: "https://<mgmt-2-ip>:8089"
      tls:
        insecure_skip_verify: true
    metrics:
      splunk.health:
        enabled: true
      splunk.parse.queue.ratio:
        enabled: true
      splunk.indexer.queue.ratio:
        enabled: true
      splunk.aggregation.queue.ratio:
        enabled: true
      splunk.typing.queue.ratio:
        enabled: true
      splunk.indexer.avg.rate:
        enabled: true
      splunk.scheduler.completion.ratio:
        enabled: true
      splunk.scheduler.avg.execution.latency:
        enabled: true
      splunk.scheduler.avg.run.time:
        enabled: true

processors:
  batch:
    timeout: 5s
    send_batch_size: 8192

exporters:
  prometheusremotewrite/local:
    endpoint: "http://127.0.0.1:9090/api/v1/write"
  debug:
    verbosity: basic

service:
  extensions:
    - health_check
    - basicauth/splunk_cm
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
    metrics/splunk_cluster_master:
      receivers:
        - splunkenterprise
      processors:
        - batch
      exporters:
        - prometheusremotewrite/local
        - debug
```

`collection_interval` set to 1m (default is 10m) for fast feedback while validating;
worth dialing back given the host's CPU constraints once steady-state behavior is
confirmed acceptable.

Used `prometheusremotewrite` pushing to Prometheus's local remote-write endpoint
(`127.0.0.1:9090/api/v1/write`) rather than adding a second pull-based `/metrics`
port on the collector — avoids repeating the port-conflict pattern already hit twice
with 8888, and Prometheus 3.x has the remote-write receiver enabled by default with
no extra flag needed.

### Errors hit along the way

1. **Receiver naming** (`splunk_enterprise` vs `splunkenterprise`) — covered above.
2. **`references processor "batch" which is not configured`** — the pipeline
   referenced `batch`, but no top-level `processors:` block existed yet defining it.
   Straightforward miss, fixed by adding the `processors:` section.
3. **8888 port conflict resurfaced** — after adding the `pipelines` and `extensions`
   keys to `service:`, the previously-working `telemetry.metrics.readers` override
   (pointing self-telemetry to 127.0.0.1:8889, to avoid colliding with Jaeger) had
   been dropped during the edit. **Lesson reinforced:** when editing the `service:`
   block, treat it as one atomic unit and supply the whole thing, rather than
   patching pieces in isolation — fragmentary edits are how previously-fixed
   settings quietly regress.

## 3. Validation

Confirmed in Prometheus via:

```
{__name__=~"splunk_.+"}
```

All nine configured metrics arrived successfully:

```
splunk_aggregation_queue_ratio
splunk_health
splunk_indexer_avg_rate_kilobytes
splunk_indexer_queue_ratio
splunk_parse_queue_ratio
splunk_scheduler_avg_execution_latency
splunk_scheduler_avg_run_time
splunk_scheduler_completion_ratio
splunk_typing_queue_ratio
```

Note the OTel-to-Prometheus name translation isn't a pure dot-to-underscore swap —
`splunk.indexer.avg.rate` picked up a `_kilobytes` unit suffix
(`splunk_indexer_avg_rate_kilobytes`). Worth keeping in mind when writing Grafana
queries or alert rules against these metrics; flagged as a follow-up item to
confirm units/semantics for each metric rather than assuming.

Spot-checking the raw `splunk_aggregation_queue_ratio` series initially looked like
it had no value, which raised a brief concern — resolved on closer inspection
(checking average throughput showed sensible, present values), but worth a closer
look at metric semantics generally before building alerting on top of these.

Visible and queryable in Grafana, confirming the full path: Splunk REST API
(mgmt-2) → `otelcol-contrib` (obs) → Prometheus remote write → Grafana.

## 4. Current scope and what's deferred

- Only `cluster_master` (mgmt-2) is configured. Expansion to `indexer` (idx-1,
  idx-2) and `search_head` (sh-1, sh-2) targets is a natural next step — the
  `search_head` metrics (`splunk.search.duration`, `splunk.search.status`,
  `splunk.search.success`) are the closest this receiver gets to per-search
  visibility, since Splunk itself doesn't expose true distributed-tracing-style
  spans for individual search execution.
- Custom SPL searches (the `metrics.log` queue-data idea) not yet attempted —
  planned next phase for this pilot.
- Capability scoping for the `otel_monitor` role (currently full `admin`
  inheritance) not yet narrowed.

## 5. Next steps

- Let the pilot run; explore the data in Grafana and build out a proper dashboard
  (queue ratio gauges, scheduler stats, throughput) at leisure.
- Possible later step: run existing load-testing tooling against the indexers and
  observe queue ratios respond live — the most direct validation that this data is
  meaningful, not just present.
- Splunk administration side-quest (SAML/SSO for the cluster) planned as the next
  work item, independent of OTel/observability-stack work, before returning to
  expand this receiver or move on to nginx/Jaeger tracing.