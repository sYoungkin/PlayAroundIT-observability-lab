# Issues & Further Improvements

This document tracks known issues, deviations from best practice, and planned improvements for the PlayAroundIT Observability Lab. Items are added as they are discovered and resolved or deferred.

---

## Open Issues

### Issue 1 — Universal Forwarder Service Account Naming

**Priority:** Low
**Component:** `scripts/splunk_uf_install.sh`

The Universal Forwarder install script creates a service account named `splunk` rather than `splunkfwd`. Splunk documentation recommends using a dedicated `splunkfwd` user for the Universal Forwarder to clearly distinguish it from the Splunk Enterprise service account (`splunk`) used on indexers, search heads, and management nodes.

The current setup is functionally correct — a non-root service account is used and follows the core security best practice. The naming is purely a convention issue.

**Suggested improvement:**
Update `splunk_uf_install.sh` to create a `splunkfwd` user instead of `splunk`, and ensure the `audit_readers` group membership and file ownership are updated accordingly.

---

### Issue 2 — OS Tuning Not Applied During Provisioning

**Priority:** Medium — Important for indexers and any node under load
**Component:** `scripts/splunk_install.sh`, `scripts/splunk_uf_install.sh`

The installation scripts do not apply the OS-level tuning that Splunk recommends as prerequisites for production deployments. The following settings are not currently configured:

**File descriptor limits (`/etc/security/limits.conf`):**
Splunk recommends a minimum of 64000 open file descriptors. The Ubuntu default is significantly lower.
```
splunk soft nofile 64000
splunk hard nofile 64000
splunk soft nproc 16000
splunk hard nproc 16000
```

**Transparent Huge Pages (THP):**
Splunk requires THP to be disabled. When THP is enabled Splunk logs a warning at startup and performance may be degraded.
```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```
THP must also be disabled persistently across reboots via a systemd service or rc.local entry — the `echo never` approach does not survive a reboot.

**Suggested improvement:**
Add an OS tuning block to both install scripts that:
- Sets ulimits for the Splunk service account in `/etc/security/limits.conf`
- Disables THP immediately and persistently via a systemd service unit
- Verifies settings are applied before Splunk starts

---

## Resolved Issues

*None yet.*

---

## Notes

- Issues are added as discovered during lab builds and configuration sessions
- Low priority items are cosmetic or minor deviations from best practice that do not affect functionality
- Medium and high priority items should be addressed before using this lab as a reference for production configurations