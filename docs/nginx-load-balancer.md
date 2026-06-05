# Nginx Search Head Cluster Load Balancer

This document covers the installation and configuration of nginx as a reverse proxy load balancer for the Splunk Search Head Cluster in the PlayAroundIT Observability Lab.

---

## Architecture

The nginx load balancer runs on the Universal Forwarder node (uf-1). This node was chosen deliberately because:

- No Splunk Web running on it — no port conflict on 8000
- Dedicated infrastructure node with spare capacity
- Clean separation of concerns — mgmt-1 IP remains accessible directly for the Deployment Server and SH Deployer UI without hostname confusion

| Component | Node | IP | Port |
|---|---|---|---|
| Load balancer | uf-1 | 192.168.248.x | 8000 |
| Search Head 1 | sh-1 | 192.168.248.207 | 8000 |
| Search Head 2 | sh-2 | 192.168.248.208 | 8000 |

**Access URL:** `http://playaroundit-shc:8000`

---

## Why Not mgmt-1?

The initial approach was to run nginx on mgmt-1 since it serves the search head tier. This created a conflict — mgmt-1 runs Splunk Web on port 8000 for the Deployment Server and SH Deployer UI. Running nginx on the same port would block access to the mgmt-1 UI.

Using a different port (e.g. 8001) on mgmt-1 was considered but adds confusion. Moving nginx to uf-1 eliminates the conflict entirely and keeps the architecture cleaner.

---

## Installation

On uf-1:

```bash
sudo apt-get update -y
sudo apt-get install -y nginx
```

---

## Configuration

Create `/etc/nginx/conf.d/splunk-lb.conf`:

```nginx
upstream splunk_search_heads {
    ip_hash;
    server 192.168.248.207:8000;
    server 192.168.248.208:8000;
}

server {
    listen 8000;
    server_name playaroundit-shc;

    location / {
        proxy_pass http://splunk_search_heads;
        proxy_redirect http://192.168.248.207:8000/ http://playaroundit-shc:8000/;
        proxy_redirect http://192.168.248.208:8000/ http://playaroundit-shc:8000/;
        proxy_set_header Host $host:$server_port;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host:$server_port;
    }
}
```

**Configuration notes:**

| Setting | Purpose |
|---|---|
| `ip_hash` | Sticky sessions — ensures the same client IP always routes to the same search head. Required because Splunk Web session cookies are tied to a specific search head |
| `proxy_redirect` | Rewrites Location headers in redirect responses — prevents the browser from bypassing the load balancer and going directly to a search head IP |
| `proxy_set_header Host` | Passes the original host header to the search head |
| `proxy_set_header X-Real-IP` | Passes the real client IP to the search head for accurate access logging |
| `proxy_set_header X-Forwarded-For` | Standard proxy header for client IP chain |
| `proxy_set_header X-Forwarded-Host` | Passes the original host and port so Splunk can construct correct redirect URLs |

**Remove the default nginx site:**

```bash
sudo rm /etc/nginx/sites-enabled/default
```

**Validate config and start:**

```bash
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl start nginx
```

**Verify nginx is listening on port 8000:**

```bash
sudo ss -tlnp | grep nginx
```

Expected output shows nginx listening on `0.0.0.0:8000`.

---

## Windows Hosts File

Add the following entry to `C:\Windows\System32\drivers\etc\hosts` (open Notepad as Administrator):

```
<uf1_ip>    playaroundit-shc
```

Replace `<uf1_ip>` with the actual IP of uf-1 from `lab_status.sh`.

**Also add to WSL `/etc/hosts` if using Ubuntu terminal:**

```bash
echo "<uf1_ip> playaroundit-shc" | sudo tee -a /etc/hosts
```

---

## Access URLs

| URL | Destination | Purpose |
|---|---|---|
| `http://playaroundit-shc:8000` | nginx → sh-1 or sh-2 | Search Head Cluster UI |
| `http://<mgmt1_ip>:8000` | mgmt-1 directly | Deployment Server / SH Deployer UI |
| `http://<mgmt2_ip>:8000` | mgmt-2 directly | Cluster Manager / License Manager / Monitoring Console UI |

---

## How the 303 Redirect Problem Was Solved

When a browser first hits `http://playaroundit-shc:8000`, nginx forwards the request to a search head. Splunk Web responds with a **303 See Other** redirect to send the browser to the login page. Without `proxy_redirect`, this redirect contains the search head's own IP in the Location header:

```
Location: http://192.168.248.207:8000/en-US/account/login
```

The browser follows this redirect directly to the search head, completely bypassing nginx. The load balancer is out of the picture for all subsequent requests.

The `proxy_redirect` directive intercepts these Location headers and rewrites them before they reach the browser:

```
Location: http://playaroundit-shc:8000/en-US/account/login
```

Now the browser follows the redirect back through nginx, maintaining the load balancer in the request path for the entire session.

---

## Nginx as a Data Source

The nginx access log at `/var/log/nginx/access.log` on uf-1 is a valuable data source for Splunk. Every request routed through the load balancer is logged with:

- Client IP address
- Timestamp
- HTTP method and requested URL
- HTTP status code
- Response size
- User agent string

This provides operational visibility into search head cluster access patterns — who is logging in, from which IPs, how often, and whether any errors are occurring. This log will be onboarded to Splunk alongside auditd and auth logs from uf-1.

---

## Verification

**Test the load balancer from the browser:**

Navigate to `http://playaroundit-shc:8000` — the Splunk login page should load.

**Confirm requests are hitting nginx:**

```bash
sudo tail -f /var/log/nginx/access.log
```

Each browser request should generate a log entry.

**Check which search head is serving the session:**

After logging in, navigate to **Settings → Server Settings → General Settings** — the server name shown will be either sh-1 or sh-2, confirming which search head nginx routed you to.

---

## Troubleshooting

**Page not loading, no events in access log:**
nginx is not listening on the expected port. Run `sudo ss -tlnp | grep nginx` — if port 8000 is not listed, restart nginx: `sudo systemctl restart nginx`. Confirm the default site is removed from `sites-enabled/`.

**303 redirect loop — page never loads:**
The `proxy_redirect` directives are missing or incorrect. Confirm both search head IPs are covered by separate `proxy_redirect` lines.

**Always hitting the same search head:**
Expected behavior — `ip_hash` ensures session stickiness by routing the same client IP to the same upstream. This is intentional to prevent session breaks.

**`playaroundit-shc` not resolving:**
The Windows hosts file entry is missing or incorrect. Confirm the entry exists with the correct uf-1 IP and that the file was saved with Administrator privileges.

**nginx config syntax error:**
Run `sudo nginx -t` — this validates the config and shows the exact line of any syntax error before attempting to reload.

---

## Notes

- nginx access logs from uf-1 will be onboarded to Splunk alongside auditd and auth logs — see `docs/splunk-universal-forwarder-configuration.md`
- If uf-1 is reprovisioned the nginx installation and config will need to be reapplied — consider adding nginx installation to `splunk_uf_install.sh` for future automation
- The `ip_hash` load balancing method means all traffic from a single client IP goes to the same search head — in a lab with one client this means you will always hit the same search head. This is correct behavior
- Search head cluster captain election is independent of the load balancer — if the captain changes the load balancer continues to function normally