# Ansible & Metricbeat — Deployment Workflow

This document covers the complete manual workflow from a freshly provisioned lab environment through to Metricbeat running on all nodes and shipping data into Elasticsearch. Follow these steps in order.

---

## Overview

After `vagrant up` completes, the elastic node has:
- Elasticsearch and Kibana running
- Ansible installed and upgraded to latest version via pip3
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

Note the IP address of every running VM. You will need these for the inventory update.

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

Replace all placeholder IPs with the actual values from `lab_status.sh`.

> **Important:** The elastic node entry uses `ansible_connection=local` only — no `ansible_host` is set. Ansible discovers the elastic node's real IP automatically via fact gathering at runtime.

```ini
[elastic_node]
elastic ansible_connection=local

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
elastic_node
splunk_all

[all:vars]
ansible_user=vagrant
ansible_ssh_private_key_file=/root/.ssh/ansible_lab
```

> **Note:** The group is named `[elastic_node]` not `[elastic]` to avoid a naming conflict between the group name and the hostname `elastic`. The hostname itself remains `elastic`.

---

## Step 3 — Create the Vault Password File

Store the vault password in a local file so you do not have to type it on every playbook run:

```bash
echo "yourvaultpassword" > /root/.vault_pass
chmod 600 /root/.vault_pass
```

This file stays on the elastic node only and is never committed to the repo.

---

## Step 4 — Create the Ansible Vault

The Elasticsearch password is stored in an encrypted vault file. This file is never committed to the repo and must be created manually on the elastic node after every fresh provision.

> **Critical:** The vault file must be created inside `/etc/ansible/inventory/group_vars/all/` — the same directory as `all.yml`. Ansible only auto-loads vault files when they are co-located with the other group_vars files next to the inventory.

```bash
ansible-vault create /etc/ansible/inventory/group_vars/all/vault.yml \
  --vault-password-file /root/.vault_pass
```

When the editor opens add:

```yaml
vault_elasticsearch_password: "adminuser123!"
```

Save and exit. The file is now encrypted on disk.

---

## Step 5 — Verify Ansible Configuration

Confirm the Ansible config file is in place and correct:

```bash
cat /etc/ansible/ansible.cfg
```

Expected content:

```ini
[defaults]
host_key_checking = False
private_key_file = /root/.ssh/ansible_lab
inventory = /etc/ansible/inventory/hosts.ini
roles_path = /etc/ansible/roles
vault_password_file = /root/.vault_pass
```

Confirm the private key is present with correct permissions:

```bash
ls -la /root/.ssh/ansible_lab
```

Expected: file exists with permissions `600` owned by `root`.

Confirm the Ansible files were correctly copied from the repo:

```bash
find /etc/ansible -type f
```

Expected: playbooks, templates, inventory, group_vars, host_vars, and ansible.cfg all present.

---

## Step 6 — Verify Vault is Correct

Confirm the vault file exists in the correct location:

```bash
ls -la /etc/ansible/inventory/group_vars/all/
```

Expected: both `all.yml` and `vault.yml` present in the `all/` subdirectory.

Confirm the vault file is encrypted:

```bash
cat /etc/ansible/inventory/group_vars/all/vault.yml
```

Expected: encrypted ciphertext starting with `$ANSIBLE_VAULT;1.1;AES256` — not readable plaintext.

Decrypt and verify the contents:

```bash
ansible-vault view /etc/ansible/inventory/group_vars/all/vault.yml \
  --vault-password-file /root/.vault_pass
```

Expected output:

```yaml
vault_elasticsearch_password: "adminuser123!"
```

> **Note:** The `ansible -m debug` command for checking vault variable resolution can show "VARIABLE IS NOT DEFINED" even when the vault is correctly configured. Use the vault view command above as the definitive verification instead.

---

## Step 7 — Validate Ansible Connectivity

Test connectivity to all provisioned hosts:

```bash
cd /etc/ansible
ansible all -m ping
```

Expected output for each host:

```
mgmt-1 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

Every host must return `SUCCESS` before proceeding.

Confirm Ansible can run commands across all hosts:

```bash
ansible all -m command -a "date"
```

Every host should return the current date and time.

> **Note:** Since `inventory` and `vault_password_file` are defined in `ansible.cfg`, the `-i` and `--vault-password-file` flags are not required when running from `/etc/ansible/`. Always run Ansible commands from `/etc/ansible/`.

---

## Step 8 — Deploy Metricbeat

Run the Metricbeat playbook:

```bash
cd /etc/ansible
ansible-playbook playbooks/metricbeat.yml
```

The playbook will:
1. Gather facts from all hosts — required so the elastic node's real IP is available to all other nodes
2. Copy the Elasticsearch CA certificate from the elastic node to all Splunk nodes
3. Install Metricbeat on all nodes from the Elastic 9.x APT repository
4. Deploy the Metricbeat configuration via Jinja2 template
5. Enable `system`, `linux`, and `beat-xpack` modules on all nodes
6. Enable `elasticsearch-xpack` and `kibana-xpack` modules on the elastic node only
7. Start and enable the Metricbeat service on all nodes
8. Run `metricbeat setup --index-management` on the elastic node

Expected runtime: 3-5 minutes.

---

## Step 9 — Validate Metricbeat Deployment

### Service status across all nodes

```bash
ansible all -m command -a "systemctl status metricbeat --no-pager"
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

Expected: one or more `metricbeat-*` indices with a document count greater than zero.

### Confirm cluster health

```bash
curl -s --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u "elastic:adminuser123!" \
  "https://localhost:9200/_cluster/health?pretty"
```

Expected: `"status": "green"` or `"status": "yellow"`. Yellow is normal for a single-node cluster.

---

## Step 10 — Create Data View in Kibana

The `metricbeat setup --index-management` command sets up Elasticsearch assets only. The Kibana data view must be created manually:

1. Open Kibana at `http://<elastic-ip>:5601`
2. Log in as `elastic` / `adminuser123!`
3. Navigate to **Management → Stack Management → Data Views**
4. Click **Create data view**
5. Set name to `metricbeat-*`
6. Set index pattern to `metricbeat-*`
7. Set timestamp field to `@timestamp`
8. Click **Save data view to Kibana**

---

## Step 11 — Validate in Kibana

1. Navigate to **Discover** → select `metricbeat-*` data view
2. Confirm metric documents are appearing with `host.name` fields populated
3. Navigate to **Observability → Infrastructure** to see host-level metrics
4. Confirm all provisioned nodes appear as hosts

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

**vault_elasticsearch_password is undefined:**
The vault file is not in the correct location. It must be at `/etc/ansible/inventory/group_vars/all/vault.yml`. Recreate it in the correct location — see Step 4.

**elasticsearch_host resolves to 127.0.0.1:**
The elastic node entry in `hosts.ini` has `ansible_host=127.0.0.1` set. Remove `ansible_host` from the elastic entry — only `ansible_connection=local` should be set. The real IP is discovered automatically via fact gathering.

**Metricbeat fails to connect to Elasticsearch on Splunk nodes:**
The CA cert was not copied correctly. Check `/etc/metricbeat/certs/http_ca.crt` exists on the failing node. Re-run the playbook to retry the cert distribution. Also confirm Metricbeat was restarted after the config was updated — restart manually with `systemctl restart metricbeat` if needed.

**No metricbeat indices in Elasticsearch:**
Check `journalctl -u metricbeat` on the failing node. Confirm the Elasticsearch host IP in the rendered config is correct: `grep -A3 "output.elasticsearch" /etc/metricbeat/metricbeat.yml`. If it shows `127.0.0.1` the fact gathering play did not run — ensure the playbook starts with the gather facts play.

**Ansible files not copied to elastic node after provisioning:**
The Vagrant file provisioner runs before the elastic install script creates `/etc/ansible`. Confirm the provisioner order in the Vagrantfile — the install script must run before the file copy provisioners.

**Module not appearing as enabled:**
Check `/etc/metricbeat/modules.d/` — enabled modules have `.yml` extension, disabled have `.yml.disabled`. Re-run the playbook to re-enable.

---

## Notes

- Always operate as `root` on the elastic node (`sudo -i`)
- Always run Ansible commands from `/etc/ansible/` so config file paths resolve correctly
- The `ansible_user` on all target nodes is `vagrant` — the default Vagrant user
- Update `hosts.ini` with current IPs after every `vagrant up` using `lab_status.sh`
- The `metricbeat.yml` config on each node is managed by Ansible via Jinja2 template — do not edit manually as it will be overwritten on the next playbook run
- `host_key_checking = False` is intentional for this lab — do not use in production
- The vault file and vault password file must be recreated after every fresh provision of the elastic node
- The elastic node's IP is resolved dynamically via `ansible_default_ipv4.address` — the fact gathering play at the start of the Metricbeat playbook is required for this to work