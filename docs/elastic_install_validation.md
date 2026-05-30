# Elastic Stack — Post-Provisioning Validation

Run these checks after provisioning the `elastic` node to confirm Elasticsearch and Kibana are installed and configured correctly.

---

## 1. Service Status

```bash
systemctl status elasticsearch.service --no-pager
systemctl status kibana.service --no-pager

# troubleshoot:
journalctl -u kibana.service -f

```

Both services should show `active (running)`. Kibana can take 60-90 seconds to fully initialize after the service starts.

---

## 2. Elasticsearch Connectivity

Test that Elasticsearch is reachable and the `elastic` superuser password is set correctly:

```bash
curl -s --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u "elastic:adminuser123!" \
  https://localhost:9200
```

**Expected output:** JSON cluster info containing `cluster_name`, `version`, and `tagline`.

---

## 3. kibana_system Password

Test that the `kibana_system` service account password was set correctly:

```bash
curl -s --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u "kibana_system:adminuser123!" \
  https://localhost:9200
```

**Expected output:** Same cluster info JSON as above. A 401 response means the `kibana_system` password reset did not complete successfully.

---

## 4. Kibana Port

Confirm Kibana is listening on port 5601:

```bash
ss -tlnp | grep 5601
```

**Expected output:** A line showing `LISTEN` on `0.0.0.0:5601`.

---

## 5. Kibana UI

Open a browser and navigate to:

```
http://<elastic-vm-ip>:5601
```

Log in with:

- **Username:** `elastic`
- **Password:** `adminuser123!`

**Expected:** Kibana home screen loads successfully.

---

## 6. Kibana Logs

If Kibana is slow to load or the UI is not accessible, check the service logs in real time:

```bash
journalctl -u kibana.service -f
```

Kibana is fully ready when the log shows:

```
Kibana is now available
```

---

## 7. Elasticsearch Cluster Health

Once logged into Kibana, or via curl:

```bash
curl -s --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u "elastic:adminuser123!" \
  https://localhost:9200/_cluster/health?pretty
```

**Expected:** `"status": "green"` or `"status": "yellow"` (yellow is normal for a single-node cluster with no replicas).

---

## Notes

- A `yellow` cluster health status is expected on a single-node Elastic deployment — it means primary shards are assigned but replicas cannot be allocated because there is only one node. This is normal for a lab environment.
- Kibana connects to Elasticsearch using the `kibana_system` built-in service account, configured directly in `/etc/kibana/kibana.yml`.
- The enrollment token flow is intentionally bypassed in this lab — Kibana is configured via direct `kibana.yml` settings instead.