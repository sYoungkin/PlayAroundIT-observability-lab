# Ansible — Initial Connectivity Validation

This document covers the initial validation of Ansible connectivity from the `elastic` control node to the lab VMs. Run these tests after provisioning to confirm SSH key distribution and Ansible are working correctly before deploying any playbooks.

---

## Prerequisites

Before running these tests confirm the following:

- The `elastic` node has been provisioned and is running
- The target node (e.g. `mgmt-1`) has been provisioned and is running
- The `ansible_lab` private key is present at `/root/.ssh/ansible_lab` on the elastic node
- The `ansible_lab.pub` public key has been injected into `/home/vagrant/.ssh/authorized_keys` on all target nodes
- The `hosts.ini` inventory file has been updated with current IP addresses

---

## 1. Confirm Private Key is Present

SSH into the elastic node and verify the key is in place:

```bash
ls -la /root/.ssh/ansible_lab
```

**Expected:** File exists with permissions `600` owned by `root`.

---

## 2. Review Ansible Configuration

```bash
cat /etc/ansible/ansible.cfg
```

**Expected:** Contains at minimum:

```ini
[defaults]
host_key_checking = False
private_key_file = /root/.ssh/ansible_lab
```

`host_key_checking = False` is required to prevent Ansible from prompting for host fingerprint confirmation on first connection.

---

## 3. Review Inventory

```bash
cat /etc/ansible/inventory/hosts.ini
```

Confirm target hosts are listed with correct IP addresses. Example structure:

```ini
# ============================================
#  Observability Lab - Ansible Inventory
#  Update IP addresses after vagrant up
#  Run: bash scripts/lab_status.sh to get IPs
# ============================================

[elastic]
elastic ansible_host=127.0.0.1 ansible_connection=local

[splunk_management]
mgmt-1 ansible_host=MGMT1_IP
mgmt-2 ansible_host=MGMT2_IP

[splunk_indexers]
idx-1 ansible_host=IDX1_IP
idx-2 ansible_host=IDX2_IP

[splunk_search_heads]
sh-1 ansible_host=SH1_IP
sh-2 ansible_host=SH2_IP

[splunk_forwarders]
uf-1 ansible_host=UF1_IP

# ============================================
#  Group of groups - targets all Splunk nodes
# ============================================
[splunk_all:children]
splunk_management
splunk_indexers
splunk_search_heads
splunk_forwarders

# ============================================
#  Group of groups - targets everything
# ============================================
[lab_all:children]
elastic
splunk_all

# ============================================
#  Variables applied to all hosts
# ============================================
[all:vars]
ansible_user=vagrant
ansible_ssh_private_key_file=/root/.ssh/ansible_lab
```

---

## 4. Test Raw SSH Connectivity

Before running Ansible, confirm raw SSH works from the elastic node to the target:

```bash
ssh -i /root/.ssh/ansible_lab vagrant@<target-ip>
```

**Expected:** Successfully logs in without password prompt or fingerprint confirmation.

If this fails, the public key was not injected correctly into the target node's `authorized_keys`.

---

## 5. Ansible Ping Test

Run the Ansible ping module against a single host first:

```bash
ansible mgmt-1 -i /etc/ansible/inventory/hosts.ini -m ping
```

**Expected output:**

```
mgmt-1 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

---

## 6. Ansible Ping All Hosts

Once a single host works, test all hosts:

```bash
ansible all -i /etc/ansible/inventory/hosts.ini -m ping
```

**Expected:** All provisioned hosts return `SUCCESS` with `pong`.

---

## 7. Basic Command Test

Run a real command across all hosts to confirm full connectivity:

```bash
ansible all -i /etc/ansible/inventory/hosts.ini -m command -a "date"
```

**Expected:** Each host returns the current date and time. Confirms Ansible can execute commands remotely, not just ping.

---

## 8. Gather Facts Test

Test that Ansible can collect system facts from a target host:

```bash
ansible mgmt-1 -i /etc/ansible/inventory/hosts.ini -m setup -a "filter=ansible_distribution*"
```

**Expected:** Returns OS distribution info for the target node. Confirms Ansible has full remote access and fact gathering works — a prerequisite for most playbooks.

---

## Troubleshooting

**Permission denied (publickey):**
The public key was not injected into the target node. Reprovision the target with `vagrant provision <vm-name>` and confirm the global public key provisioner ran.

**Host key verification failed:**
`host_key_checking` is not set to `False` in `ansible.cfg`. Add or confirm the setting and retry.

**Unreachable — connection timed out:**
The target VM is not running or the IP in `hosts.ini` is incorrect. Run `bash scripts/lab_status.sh` to confirm current IPs and update the inventory.

**Private key file not found:**
The `ansible_lab` private key was not copied to `/root/.ssh/` during provisioning. Re-run `vagrant reload elastic --provision` to re-inject it.

---

## Notes

- Always run Ansible as `root` on the elastic node (`sudo -i` or log in as root directly)
- The `ansible_user` is `vagrant` on all target nodes — this is the default user created by Vagrant on every VM
- Update `hosts.ini` with actual IPs after each `vagrant up` using the output from `bash scripts/lab_status.sh`
- `host_key_checking = False` is intentional for this lab environment — do not use this setting in production