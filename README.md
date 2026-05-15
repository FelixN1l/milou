# milou

Public install + release distribution for [milou-backend](https://github.com/FelixN1l/milou-backend) — an SSPanel-Metron / soga-v1-compatible multi-protocol proxy daemon.

The daemon source code is private. Binaries, install scripts, and the management wrapper live here.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/FelixN1l/milou/main/install.sh)
```

After install:

```bash
milou init        # interactive config: panel keys, cert, listen IP
milou cert issue  # if cert_mode=http or dns
milou start
milou status      # confirm it came up
milou log         # tail the journal
```

## Files

| file | role |
|------|------|
| [`install.sh`](install.sh) | one-shot installer; fetches the matching tarball from this repo's Releases, drops binaries + scripts into `/usr/local/milou` + `/etc/milou`, registers the systemd unit |
| [`milou.sh`](milou.sh) | management wrapper; installed as `/usr/bin/milou` |
| [`milou.service`](milou.service) | singleton systemd unit (`/etc/milou/milou.conf`) |
| [`milou@.service`](milou@.service) | template unit for multi-instance hosts (`milou@<name>` reads `/etc/milou/<name>.conf`) |
| [`milou.conf.default`](milou.conf.default) | config template shipped to `/etc/milou/milou.conf` on first install |

## Multi-instance on one host

Run a second instance pinned to its own IP:

```bash
cp /etc/milou/milou.conf /etc/milou/extra.conf
# in extra.conf: set listen=<the other IP>, node_id=<other node>, ...
systemctl enable --now milou@extra.service
journalctl -u milou@extra -f
```

The singleton `milou` CLI manages `milou.service` only; manage extras directly via `systemctl`.

## Versions

Each release tag publishes:

- `milou-vX.Y.Z-linux-amd64.tar.gz`
- `milou-vX.Y.Z-linux-arm64.tar.gz`
- `SHA256SUMS`

Pin a version via `MILOU_VERSION=vX.Y.Z bash <(curl -fsSL ...)`. The install script verifies SHA256 before extracting.

## Source

Daemon source: [FelixN1l/milou-backend](https://github.com/FelixN1l/milou-backend) (private).
