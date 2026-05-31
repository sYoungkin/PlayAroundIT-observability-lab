# Ansible & Metricbeat — Deployment Workflow

This document covers the complete manual workflow from a freshly provisioned lab environment through to Metricbeat running on all nodes and shipping data into Elasticsearch. Follow these steps in order.

---

## Overview

After `vagrant up` completes, the elastic node has:
- Elasticsearch and Kibana running
- Ansible installed
- All playbooks, templates, and group_vars copied to `/etc/ansible/`
- Ansible private key at `/root/.ssh/ansible_lab`
- Public key injected into all other VMs

The following steps must be completed manually before running any playbook.

---

## Step 1 — Get VM IP Addresses

Run on your local machine after provisioning:

```bash
bash scripts/lab_status.sh
```

Note the IP address of every running VM. You will need these for the next two steps.

---

## Step 2 — Update Ansible Inventory

SSH into the elastic node:

```bash
vagrant ssh elastic
sudo -i
```

Edit the inventory file:

```bash
vi /etc/ansible/inventory/hosts.ini
```

Replace all placeholder IPs with the actual values from `lab_status.sh`. The elastic node entry uses localhost and does not need an IP:

```ini
[elastic]
elastic ansible_host=127.0.0.1 ansible_connection=local

[splunk_management]
mgmt-1 ansible_host=192.168.x.x
mgmt-2 ansible_host=192.168.x.x

[splunk_indexers]
idx-1 ansible_host=192.168.x.x
idx-2 ansible_host=192.168.x.x

[splunk_search_heads]
sh-1 ansible_host=192.168.x.x
sh-2 ansible_host=192.168.x.x

[splunk_forwarders]
uf-1 ansible_host=192.168.x.x

[splunk_all:children]
splunk_management
splunk_indexers
splunk_search_heads
splunk_forwarders

[lab_all:children]
elastic
splunk_all

[all:vars]
ansible_user=vagrant
ansible_ssh_private_key_file=/root/.ssh/ansible_lab
```

---

## Step 3 — Create the Ansible Vault

The Elasticsearch password is stored in an encrypted vault file. This file is never committed to the repo and must be created manually on the elastic node after every fresh provision.

```bash
ansible-vault create /etc/ansible/group_vars/vault.yml
```

You will be prompted to set a vault password. Enter and confirm it. When the editor opens add:

```yaml
vault_elasticsearch_password: "adminuser123!"
```

Save and exit. The file is now encrypted on disk.

---

## Step 4 — Create the Vault Password File

Store the vault password in a local file so you do not have to type it on every playbook run:

```bash
echo "yourvaultpassword" > /root/.vault_pass
chmod 600 /root/.vault_pass
```

This file stays on the elastic node only and is never committed to the repo.

---

## Step 5 — Verify Ansible Configuration

Confirm the Ansible config file is in place:

```bash
cat /etc/ansible/ansible.cfg
```

Expected content:

```ini
[defaults]
host_key_checking = False
private_key_file = /root/.ssh/ansible_lab
```

Confirm the private key is present:

```bash
ls -la /root/.ssh/ansible_lab
```

Expected: file exists with permissions `600` owned by `root`.

---

## Step 6 — Validate Ansible Connectivity

Test connectivity to all hosts before running any playbook:

```bash
ansible all -i /etc/ansible/inventory/hosts.ini \
  -m ping \
  --vault-password-file /root/.vault_pass
```

**Expected output for each host:**

```
mgmt-1 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

Every host must return `SUCCESS` before proceeding. If any host fails see the troubleshooting section below.

Confirm Ansible can run commands across all hosts:

```bash
ansible all -i /etc/ansible/inventory/hosts.ini \
  -m command -a "date" \
  --vault-password-file /root/.vault_pass
```

Every host should return the current date and time.

---

## Step 7 — Verify group_vars Are Loaded

Confirm Ansible can resolve the vault secret correctly:

```bash
ansible all -i /etc/ansible/inventory/hosts.ini \
  -m debug -a "var=elasticsearch_password" \
  --vault-password-file /root/.vault_pass
```

**Expected:** Every host returns `"elasticsearch_password": "adminuser123!"` — not the raw vault variable reference.

If you see `"elasticsearch_password": "{{ vault_elasticsearch_password }}"` the vault was not created correctly. Repeat Step 3.

---

## Step 8 — Deploy Metricbeat

Run the Metricbeat playbook against all nodes:

```bash
ansible-playbook /etc/ansible/playbooks/metricbeat.yml \
  -i /etc/ansible/inventory/hosts.ini \
  --vault-password-file /root/.vault_pass
```

The playbook will:
1. Copy the Elasticsearch CA certificate from the elastic node to all Splunk nodes
2. Install Metricbeat on all nodes from the Elastic 9.x APT repository
3. Deploy the Metricbeat configuration via Jinja2 template
4. Enable `system`, `linux`, and `beat-xpack` modules on all nodes
5. Enable `elasticsearch-xpack` and `kibana-xpack` modules on the elastic node only
6. Start and enable the Metricbeat service on all nodes

Expected runtime: 3-5 minutes.

---

## Step 9 — Validate Metricbeat Deployment

### Service status across all nodes

```bash
ansible all -i /etc/ansible/inventory/hosts.ini \
  -m command -a "systemctl status metricbeat --no-pager" \
  --vault-password-file /root/.vault_pass
```

All nodes should show `active (running)`.

### Check Metricbeat logs on a specific node

SSH into any node and run:

```bash
journalctl -u metricbeat -f
```

Look for successful output connection messages. No `ERROR` lines relating to connection or output.

### Confirm Metricbeat indices in Elasticsearch

From the elastic node:

```bash
curl -s --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u "elastic:adminuser123!" \
  "https://localhost:9200/_cat/indices?v" | grep metricbeat
```

**Expected:** One or more `metricbeat-*` indices with a document count greater than zero.

### Confirm cluster health

```bash
curl -s --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u "elastic:adminuser123!" \
  "https://localhost:9200/_cluster/health?pretty"
```

**Expected:** `"status": "green"` or `"status": "yellow"`. Yellow is normal for a single-node cluster.

---

## Step 10 — Validate in Kibana

1. Open Kibana at `http://<elastic-ip>:5601`
2. Log in as `elastic` / `adminuser123!`
3. Navigate to **Management → Stack Management → Index Management**
4. Confirm `metricbeat-*` indices are present with documents
5. Navigate to **Discover**, select the `metricbeat-*` data view
6. Confirm metric documents are appearing with `host.name` fields populated
7. Navigate to **Observability → Infrastructure** to see host-level metrics

---

## Modules Deployed

### All nodes
| Module | Purpose |
|---|---|
| `system` | CPU, memory, disk, network, process metrics |
| `linux` | Kernel metrics, page faults, pressure stall |
| `beat-xpack` | Metricbeat self-monitoring |

### Elastic node only
| Module | Purpose |
|---|---|
| `elasticsearch-xpack` | Cluster health, node stats, index stats |
| `kibana-xpack` | Kibana status and performance metrics |

---

## Troubleshooting

**Ansible ping fails — Permission denied (publickey):**
The public key was not injected into the target node. Reprovision with `vagrant provision <vm-name>` and confirm the global public key provisioner ran.

**Ansible ping fails — Host unreachable:**
The IP in `hosts.ini` is wrong or the VM is not running. Run `bash scripts/lab_status.sh` and update the inventory.

**group_vars vault variable not resolving:**
The vault file does not exist or was created with a different password. Re-run Step 3 and confirm the vault password file matches.

**Metricbeat fails to connect to Elasticsearch on Splunk nodes:**
The CA cert was not copied correctly. Check `/etc/metricbeat/certs/http_ca.crt` exists on the failing node. Re-run the playbook to retry the cert distribution.

**No metricbeat indices in Elasticsearch:**
Check `journalctl -u metricbeat` on the failing node. Confirm the Elasticsearch host IP in `group_vars/all.yml` is correct and port 9200 is reachable from that node.

**Module not appearing as enabled:**
Check `/etc/metricbeat/modules.d/` — enabled modules have `.yml` extension, disabled have `.yml.disabled`. Re-run the playbook to re-enable.

---

## Notes

- Always operate as `root` on the elastic node (`sudo -i`)
- The `ansible_user` on all target nodes is `vagrant` — the default Vagrant user
- Update `hosts.ini` with current IPs after every `vagrant up` using `lab_status.sh`
- The `metricbeat.yml` config on each node is managed by Ansible — do not edit manually as it will be overwritten on the next playbook run
- `host_key_checking = False` is intentional for this lab — do not use in production
- The vault file and vault password file must be recreated after every fresh provision of the elastic node