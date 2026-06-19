# NAT Gateway Setup

A production-grade, self-configuring NAT gateway script for Linux servers. Download and run on any Linux instance to configure full NAT in one command — no manual iptables knowledge required.

## Quick Start

```bash
# Download and run
curl -O https://raw.githubusercontent.com/mashhoudrajput/nat-gateway-setup/main/setup-nat.sh
chmod +x setup-nat.sh
sudo ./setup-nat.sh
```

Everything is auto-detected: outbound interface, private subnets, OS/distro, and on AWS — the VPC CIDR via IMDS.

---

## What It Does

- Detects OS family (Debian/Ubuntu, RHEL/Amazon Linux/CentOS/Fedora, Arch)
- Installs `iptables` and persistence tools if missing
- Auto-detects the primary outbound network interface
- Auto-detects private subnets; on AWS queries IMDSv2 for VPC CIDR
- Enables IPv4 forwarding persistently via `/etc/sysctl.d/`
- Configures iptables `MASQUERADE` + `FORWARD` rules (comment-tagged for idempotency)
- Backs up existing iptables state before any changes
- Flushes own stale rules before re-applying — safe to re-run
- Persists rules across reboots using the distro-appropriate method
- Rolls back all changes on any failure via ERR trap
- Prevents concurrent execution via `flock`
- Detects AWS EC2 and prints the Source/Destination check reminder

---

## Usage

```bash
sudo ./setup-nat.sh [OPTIONS]
```

| Option | Description |
|--------|-------------|
| `--iface IFACE` | Override outbound interface auto-detection |
| `--cidrs CIDR[,...]` | Override subnet auto-detection (comma-separated) |
| `--dry-run` | Show what would be done; make no changes |
| `--uninstall` | Remove all NAT rules and disable IP forwarding |
| `--status` | Show current NAT configuration and exit |
| `--verbose` | Enable debug-level output |
| `-h`, `--help` | Show help |

**Environment variable overrides:**

```bash
NAT_IFACE=eth0 sudo ./setup-nat.sh
NAT_CIDRS="10.0.0.0/16,192.168.1.0/24" sudo ./setup-nat.sh
```

---

## AWS Setup

When running on an EC2 instance as a NAT gateway, two AWS-side changes are required:

### 1. Disable Source/Destination Check

```bash
aws ec2 modify-instance-attribute \
  --instance-id <your-instance-id> \
  --no-source-dest-check
```

### 2. Add Route in Private Subnet's Route Table

In the AWS Console or CLI, add a route to the private subnet's route table:

| Destination | Target |
|-------------|--------|
| `0.0.0.0/0` | Instance ID of this NAT instance |

```bash
aws ec2 create-route \
  --route-table-id rtb-XXXXXXXX \
  --destination-cidr-block 0.0.0.0/0 \
  --instance-id <your-instance-id>
```

---

## Verification

**On the NAT instance:**

```bash
# Check script status
sudo ./setup-nat.sh --status

# Verify iptables rules
sudo iptables -t nat -L POSTROUTING -v -n
sudo iptables -L FORWARD -v -n

# Confirm IP forwarding
sysctl net.ipv4.ip_forward
# Expected: net.ipv4.ip_forward = 1
```

**From a private instance** (no public IP, routing through this NAT):

```bash
# Should return the NAT instance's public IP
curl -s https://checkip.amazonaws.com

# Test connectivity
ping -c 3 8.8.8.8
```

**Watch live traffic flow:**

```bash
watch -n1 'sudo iptables -t nat -L POSTROUTING -v -n'
# Run traffic from a private instance and watch packet/byte counters increment
```

---

## Idempotency

Safe to re-run at any time. Each run:

1. Removes own previously installed rules (identified by `/* setup-nat */` comment tag)
2. Removes legacy untagged rules from older versions
3. Re-applies a clean set of rules

Running it 10 times produces the same result as running it once.

---

## Uninstall

```bash
sudo ./setup-nat.sh --uninstall
```

Removes all iptables rules tagged with `setup-nat`, removes the sysctl config, and disables IP forwarding.

---

## Supported Distros

| Distro | Persistence method |
|--------|--------------------|
| Debian / Ubuntu | `iptables-persistent` + `netfilter-persistent` |
| Amazon Linux / RHEL / CentOS / Fedora | `iptables-services` |
| Arch Linux | `iptables` systemd service |

---

## Files Created

| Path | Purpose |
|------|---------|
| `/etc/sysctl.d/99-nat-gateway.conf` | Persistent IP forwarding config |
| `/etc/iptables/rules.v4` | Saved iptables rules (Debian) |
| `/var/lib/setup-nat/backups/` | Pre-run iptables backups |
| `/var/run/setup-nat.lock` | Concurrent execution lock |

---

## Requirements

- Linux with `iptables` (installed automatically if missing)
- Root / `sudo` access
- `curl` (for AWS IMDS queries)
- `ip` command (`iproute2` package)
