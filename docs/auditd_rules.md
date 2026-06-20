# auditd Lab Rules Reference

**Node:** uf-1 (primary target; rules can be adapted for other nodes via Ansible)
**File:** `/etc/audit/rules.d/99-lab-rules.rules`
**Purpose:** Generate realistic, high-volume audit event data for Kibana and Splunk
**Based on:** Neo23x0 and CISA/NSA best practice rulesets, filtered for lab use

## The Rules

```ini
## ============================================
## PlayAroundIT Lab - auditd Rules
## Based on Neo23x0 and CISA/NSA best practices
## ============================================

## -- Execution monitoring --
## All program executions - high volume but essential
-a always,exit -F arch=b64 -S execve -k exec
-a always,exit -F arch=b32 -S execve -k exec

## -- Privilege escalation --
-a always,exit -F arch=b64 -S setuid -S setgid -S setreuid -S setregid -k privilege_escalation
-a always,exit -F arch=b32 -S setuid -S setgid -S setreuid -S setregid -k privilege_escalation

## -- Sudo usage --
-w /usr/bin/sudo -p x -k sudo_usage
-w /etc/sudoers -p wa -k sudoers_change
-w /etc/sudoers.d/ -p wa -k sudoers_change

## -- User and group management --
-w /etc/passwd -p wa -k user_management
-w /etc/group -p wa -k user_management
-w /etc/shadow -p wa -k user_management
-w /etc/gshadow -p wa -k user_management
-w /usr/sbin/useradd -p x -k user_management
-w /usr/sbin/userdel -p x -k user_management
-w /usr/sbin/usermod -p x -k user_management
-w /usr/sbin/groupadd -p x -k user_management
-w /usr/sbin/groupdel -p x -k user_management
-w /usr/sbin/groupmod -p x -k user_management

## -- Authentication --
-w /var/log/auth.log -p wa -k auth_log
-w /var/log/faillog -p wa -k auth_log
-w /var/log/lastlog -p wa -k auth_log
-w /bin/su -p x -k su_usage

## -- Network activity --
-a always,exit -F arch=b64 -S connect -k network_connect
-a always,exit -F arch=b32 -S connect -k network_connect
-a always,exit -F arch=b64 -S bind -k network_bind
-a always,exit -F arch=b32 -S bind -k network_bind

## -- File permission changes --
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -k file_permission_change
-a always,exit -F arch=b32 -S chmod -S fchmod -S fchmodat -k file_permission_change
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -k file_ownership_change
-a always,exit -F arch=b32 -S chown -S fchown -S fchownat -S lchown -k file_ownership_change

## -- Kernel module loading --
-w /sbin/insmod -p x -k module_load
-w /sbin/rmmod -p x -k module_load
-w /sbin/modprobe -p x -k module_load
-a always,exit -F arch=b64 -S init_module -S delete_module -k module_load

## -- SSH --
-w /etc/ssh/sshd_config -p wa -k ssh_config
-w /root/.ssh -p wa -k ssh_keys
-w /home -p wa -k ssh_keys

## -- Cron --
-w /etc/cron.d/ -p wa -k cron
-w /etc/cron.daily/ -p wa -k cron
-w /etc/cron.hourly/ -p wa -k cron
-w /etc/crontab -p wa -k cron
-w /var/spool/cron/ -p wa -k cron

## -- System startup --
-w /etc/init.d/ -p wa -k startup
-w /etc/systemd/ -p wa -k startup

## -- Make rules immutable - comment out during testing --
## -e 2
```

## Loading and Verification

After writing the file:

```bash
# Load the rules
sudo augenrules --load

# Verify rules are active and count loaded rules
sudo auditctl -l | head -30

# Check auditd status
sudo auditctl -s

# Restart auditd to be sure
sudo systemctl restart auditd
sudo systemctl status auditd
```

## Notes on Key Rules

**`execve` (exec):** Captures every program execution on the system — both b64 and b32 arch variants needed for completeness. This is the highest-volume rule by far; on an active node every shell command, cron job, and background process generates an event. Intentionally noisy — this is the main driver of realistic data volume.

**`connect` / `bind` (network_connect / network_bind):** Captures all network socket operations at the syscall level — every outbound TCP connection attempt and every port bind. Generates significant volume on a node running nginx, Beats agents, and Splunk UF. Both arches required.

**`setuid` / `setgid` family (privilege_escalation):** Captures privilege transitions. High value for security use cases and generates events from sudo, cron, and setuid binaries like `ping`.

**`chmod` / `chown` family (file_permission_change / file_ownership_change):** Captures all permission and ownership changes. Lower volume than exec/connect but useful for file integrity correlation.

**`-w` (watch) rules:** These use the `-p` flag for permissions: `r` = read, `w` = write, `x` = execute, `a` = attribute change. `wa` on config files means "alert on any write or attribute change." `x` on binaries means "alert whenever executed."

**`-e 2` (immutable mode):** Left commented out. When enabled, the kernel refuses any further rule changes until reboot — production hardening practice. Leave commented during lab work so rules can be modified and reloaded without rebooting.

## Consumer Context

These rules feed two consumers simultaneously:

- **Splunk** via `auditd` scripted inputs in `Splunk_TA_nix` (`rlog.sh`) — picked up automatically once rules are loaded
- **Elastic/Kibana** via Auditbeat (`auditd` module in `multicast` mode) — multicast allows both to coexist without conflict

Auditbeat is configured in `multicast` mode (`socket_type: multicast`) specifically because auditd is already running and managing these rules. In `unicast` mode Auditbeat would need to take exclusive control of the audit socket, which would break the Splunk scripted input path.

## Useful Queries After Deployment

**Kibana Discover:**
```
event.module: auditd AND event.action: executed
event.module: auditd AND tags: network_connect
event.module: auditd AND tags: privilege_escalation
```

**Splunk:**
```
index=linux sourcetype=linux:audit key=exec
index=linux sourcetype=linux:audit key=network_connect
index=linux sourcetype=linux:audit key=privilege_escalation
```
