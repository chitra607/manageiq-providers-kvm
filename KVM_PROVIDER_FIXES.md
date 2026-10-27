# KVM provider — review fixes (24-10-2026)

Scope: provider **add**, **credential validation** and **inventory refresh**, plus the
crashers found on the way. Everything below was run against a real `libvirtd` 10.0 /
QEMU 8.2 host over SSH and against libvirt's `test:///` driver, using the real
`ruby-libvirt` gem (ManageIQ core itself was stubbed — run `bundle exec rspec`
in your dev environment before release).

---

## 1. Test results

### "Validate" button (`verify_credentials`)

| Case | Before | After |
|---|---|---|
| root / libvirt-group user, right password | OK | OK |
| sshd that only allows keyboard-interactive | "Invalid credentials" | OK |
| Edit form, password left blank | "Invalid credentials" | OK (stored password used) |
| **Wrong password** | **hangs forever** (worker stuck) | fails in 3 s: "Authentication failed…" |
| User not in `libvirt` group | "Invalid credentials" | "SSH login worked, but libvirt … refused …" |
| Nothing listening on the port (e.g. 9090) | "Invalid credentials" | "Connection refused … (9090 is Cockpit, not SSH)" |
| Unroutable host | "Invalid credentials" (10 s) | "Cannot reach host:22 — connection timed out" (10 s) |
| Unknown hostname | "Invalid credentials" | "Host … is unreachable: Name or service not known" |
| SSH key: authorized / Edit with stored key | — (not supported) | OK |
| SSH key: key not authorized / garbage key | — | "SSH key rejected …" / "private key could not be used" |
| SSH key: host key changed | — | refused: "SSH host key check failed … ssh-keygen -R" |

### Refresh

| | Before | After |
|---|---|---|
| Any VM | crash: `operating_systems` collection missing in persister | OK |
| VM with a snapshot | crash: `undefined method 'snapshot_current'` | OK (parent, current flag, create time) |
| 300 running VMs | 300 × `sleep 1` for CPU % (5 min) | one 1 s sample window for all VMs |
| libvirt connection | never closed (held until GC) | opened once, closed after collection |
| Real host, 7 VMs, SSH-key transport | — | 1.3 s, 1 connection opened / 1 closed |

---

## 2. Transport — use SSH key: **YES**

`qemu+libssh` (password) has a client-side bug with libvirt 10.0 + libssh 0.10.6:
some replies never return in a process that runs no libvirt event loop — every
ManageIQ worker. Reproduced: domain XMLs of 9 KB, 16–18 KB and the 19 KB host
`capabilities` hang; 3 KB and 25 KB return. `virsh` hides it because it runs an
event loop (and still stalls 5 s per such reply). A Ruby event loop was tried and
did **not** fix it.

`qemu+ssh` (OpenSSH client + private key) returned every one of those replies in
< 5 ms. The form now has **Authentication: SSH private key (recommended) / Password**.
Password still works for existing providers, but the refresh can hang on some hosts.

Check an existing appliance (exits with HUNG if affected):

```bash
cd /var/www/miq/vmdb
timeout 120 bin/rails r '
  ems = ManageIQ::Providers::Kvm::InfraManager.find_by!(:name => "KVM01")
  ems.with_provider_connection do |c|
    c.list_all_domains.each(&:xml_desc)
    puts "capabilities #{c.capabilities.size} bytes"
  end
  puts "OK"' || echo "HUNG or FAILED"
```

---

## 3. Setup procedure — SSH key

1. Create the key (any Linux box; no passphrase — workers cannot type one):
   ```bash
   ssh-keygen -t ed25519 -N '' -C manageiq-kvm -f ./miq_kvm
   ```
2. On **each** KVM host (root or a service user in the `libvirt` group):
   ```bash
   useradd -m -G libvirt miqsvc            # skip if you use root
   install -d -m 700 -o miqsvc -g miqsvc /home/miqsvc/.ssh
   cat miq_kvm.pub >> /home/miqsvc/.ssh/authorized_keys
   chown miqsvc:miqsvc /home/miqsvc/.ssh/authorized_keys && chmod 600 /home/miqsvc/.ssh/authorized_keys
   systemctl is-active libvirtd virtqemud   # one of them must be active
   ```
3. Test from the appliance as the user the workers run as (the key file must be
   readable by `manageiq`):
   ```bash
   install -o manageiq -m 600 miq_kvm /tmp/miq_kvm
   sudo -u manageiq virsh -c "qemu+ssh://miqsvc@KVM01/system?keyfile=/tmp/miq_kvm&no_tty=1" list --all
   rm -f /tmp/miq_kvm
   ```
4. UI: **Compute › Infrastructure › Providers › Add a new Infrastructure Provider** →
   Type *Red Hat KVM* → Hostname, SSH Port `22`, Authentication *SSH private key*,
   Username `miqsvc`, paste the **private** key → **Validate** → **Add**.
5. First connect stores the host key in `~manageiq/.ssh/known_hosts` (accept-new).
   After a host reinstall: `sudo -u manageiq ssh-keygen -R KVM01` (or `'[KVM01]:2222'`).

---

## 4. What was fixed

### Provider add / validation — `infra_manager.rb`
- `verify_credentials` rescued its own errors and re-raised **"Invalid credentials"** for
  everything (refused port, timeout, DNS, libvirt group, libvirtd down).
- Wrong password: the auth callback re-sent the same password until sshd's MaxAuthTries,
  then `virConnectOpenAuth` hung forever. The password is now answered once.
- Edit form: blank password/key now falls back to the stored one (`args["id"]`).
- `hostname_required?` was `false` → the same host could be added twice, empty hostname allowed.
- Connections opened by validation were never closed; `disconnect` added so
  `with_provider_connection` closes them.
- User name is URI-escaped, IPv6 literals bracketed, `keyboard-interactive` offered.
- polkit / "Permission denied" were reported as a wrong password; now
  "user may not manage libvirt".
- Removed fake code copied from a sample provider: random `events`, `metrics_old`,
  `perf_rollup_parents`; `find_vm` compared id with a string (always nil);
  `vm_migrate_workflow_class` pointed to a class that does not exist.

### Refresh — `inventory/collector.rb`, `parser.rb`, `persister.rb`, `inventory.rb`
- Persister: added `operating_systems` (missing → refresh crashed on the first VM).
- Added `Kvm::InfraManager::Snapshot` — `::Snapshot` is STI, so without a subclass the
  `:snapshots` collection raises `NotSubclassedError` and no refresh is saved.
  Snapshots are now also nested (parent link), not only `parent_uid`.
- `snapshot_current` → `current_snapshot` (crashed on every VM with a snapshot).
- `memory_stats` read via `@val` ivar and `nil - nil` crash without balloon driver.
- Guest-agent call used timeout `-1`; now 5 s.
- `host.state`, `kernel_version = CPU model`, `cpu_sockets` per NUMA node — corrected
  (`power_state`, `connection_state`, sockets × nodes, CPU speed/model, SMBIOS vendor/model).
- Networks: `:switches`/`:lans` had no builder and no provider scope → now
  `host_virtual_switches` / `host_virtual_lans` (same rows are matched, no duplicates);
  VM NICs are linked to their Lan.
- `storage_files` had no EMS association to compare against → custom `arel`.
- IPs: guest agent, then libvirt DHCP leases; IPv6 kept (was collapsed into one row);
  `Network#hostname` was set to the hypervisor name.
- Disks: `type='volume'` and network (rbd) disks, size from `blockinfo` for disks outside
  pools, default disk type `raw` (was `qcow2`), CD-ROMs excluded from disk capacity.
- Guest OS from guest agent / libosinfo metadata (was always "unknown").
- Storage type typo `iscs` → `iscsi`.
- Templates (unused qcow2/raw volumes): collection added, off by default —
  `:ems_refresh: :kvm: :discover_templates: true` to enable.

### Other crashers
- `GuestDevice` NIC helpers were private **instance** methods called from class methods
  (`raw_add_nic`, `raw_edit_nic`, `physical_networks` → NoMethodError).
- `Lan`, `StorageFile`, `GuestDevice` inherited from classes core does not have → NameError.
- Snapshots: core calls `raw_create_snapshot(name, desc, memory)` positionally (was keyword →
  ArgumentError); `snapshot_lookup_by_name` → `lookup_snapshot_by_name`;
  `Snapshot#revert` → `Domain#revert_to_snapshot`.
- Migration flag `4` is TUNNELLED, not PEER2PEER → every migration failed; now
  LIVE | PERSIST_DEST | UNDEFINE_SOURCE with both connections held by ManageIQ.
- `Provision::VALID_REQUEST_TYPES = %w[template, clone_to_vm]` contained `"template,"`.
- Event names did not match `settings.yml` (`KVMinstance_power_on`) → now `KVMVmPoweredOnEvent` etc.
- Metrics: memory % was always ~100 %, network always 0 (`dom_stats`/`interface_stats` do not exist).
- `settings.yml` overrode **global** `:performance` settings (1-minute capture for every provider) — removed.
- Removed dead files with wrong names for Zeitwerk: `ssh_key_manager.rb`, `vm/operations/snapshot_bk.rb`.

---

## 5. Upgrade notes
- Commit `libexec/kvm-ssh` with its executable bit (`git add --chmod=+x libexec/kvm-ssh`).
- *Authentication* defaults to Password so existing providers open unchanged in the Edit
  form; switch each one to *SSH private key* (section 3).
- Restart workers after deploying: `systemctl restart evmserverd`.

## 6. Not changed (follow-ups)
- Other operations (`raw_add_kvm_disk`, `raw_add_nic`, console, cloning, pool/network create)
  still call `ems.connect` without closing.
- `raw_edit_disk` / `raw_remove_disk` only trigger a refresh.
- Event-driven refresh needs Automate instances under `/System/Event/EmsEvent/KVM/`.
- Host C&U is declared (`supports :capture`) but not collected.
- Migration assumes shared storage. IPv6 path not tested (test box had no IPv6).
