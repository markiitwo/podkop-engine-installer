**English** | [Русский](README.ru.md)

# podkop-engine-installer

Installer of [podkop-engine](https://github.com/podkop-net/podkop-engine) for OpenWrt with [podkop](https://github.com/itdoginfo/podkop) already configured.

podkop-engine is a sing-box build patched for podkop. The script replaces `sing-box` / `sing-box-tiny` with it and updates podkop. podkop settings (`/etc/config/podkop`) are not changed.

## podkop-engine features

- **XHTTP:** `vless://…type=xhttp` links in podkop.
- **Fallback links in URLTest:** used when none of the main nodes answers.
- **Download check:** 64 KiB are downloaded through a node before switching to it.
- **Provider DNS fallback:** when a DNS server reached directly over WAN fails.
- **Crash protection (failsafe):** if sing-box keeps crashing, podkop is stopped so DNS in the network keeps working.
- **Go memory limit** follows the memory the router can still give.

See the [podkop-engine releases](https://github.com/podkop-net/podkop-engine/releases) for details.

## Requirements

| | |
|---|---|
| OpenWrt | 24.10 (`opkg`) or 25.12 (`apk`); the package manager is detected automatically. Snapshots are not tested |
| Architecture | `aarch64_cortex-a53`; checked via `apk --print-arch`, `/etc/apk/arch` and `DISTRIB_ARCH` |
| podkop | 0.7.0 or newer, installed and configured |
| Memory | ≥ 50 MB free, counting the memory used by the current sing-box |
| `/tmp` | ≥ 25 MB free |
| Flash | room for the podkop-engine package (~22 MB) minus the size of the current sing-box binary |
| Conflicts | `https-dns-proxy` must be removed (it conflicts with podkop) |

Tested on Xiaomi AX3000T (OpenWrt 24.10, 25.12) and Cudy WR3000S v1 (25.12).

## Versions

By default the script installs the **latest releases** of podkop-engine and podkop from GitHub. Packages are verified against the SHA-256 digests GitHub publishes for release assets.

Tested versions are built into the script. They are used with `--pinned` and automatically when the GitHub API is unavailable:

| Package | Tested version |
|---|---|
| podkop-engine | 1.14.2-r14 |
| podkop, luci-app-podkop, luci-i18n-podkop-ru | 0.7.24 |

The script only updates: if the installed podkop or podkop-engine is newer than the target, it is left as is. If both are up to date, nothing is installed.

## Usage

```sh
wget -O /root/pe.sh https://raw.githubusercontent.com/markiitwo/podkop-engine-installer/main/install.sh
sh /root/pe.sh check
sh /root/pe.sh
```

On start the script asks for the interface language (English / Русский, arrow keys and Enter; English by default). Questions are answered `y` / `n`.

| Command | Action |
|---|---|
| `sh pe.sh` | Install or update. Shows the plan and asks for confirmation first |
| `sh pe.sh check` | Check requirements only, change nothing |
| `sh pe.sh rollback` | Switch back from podkop-engine to the regular sing-box |
| `sh pe.sh report` | Diagnostic report, see [Report](#report) |
| `sh pe.sh help` | Help |

| Option | Action |
|---|---|
| `-y`, `--yes` | No questions: default answers are used |
| `--pinned` | Install the tested versions instead of the latest releases |
| `--no-rollback` | Do not roll back automatically when the post-install check fails |
| `--lang en\|ru` | Interface language without the selection menu |

`install` and `rollback` need an interactive terminal; without one the script exits unless `-y` is given.

podkop is stopped for about 1–2 minutes during installation. A dropped SSH session does not interrupt it.

## How it works

1. **Check:** OpenWrt version and package manager, architecture, podkop version, proxy sections, target versions, memory, flash, `/tmp`, DNS, whether the proxy works right now.
2. **Preparation, while podkop is still running:**
   - if podkop dependencies are missing (`curl jq kmod-nft-tproxy coreutils-base64 bind-dig ca-bundle`): package lists are updated and the missing packages installed;
   - podkop-engine and podkop packages are downloaded and verified (SHA-256);
   - a copy of the current sing-box package is saved for rollback; if it cannot be downloaded, the current sing-box files are copied to RAM for an automatic rollback within the same run.
3. **Backup:** `/etc/config/podkop`, `/etc/config/sing-box`, `/etc/config/dhcp`, `/etc/sing-box`, and on 25.12 also `/etc/apk/world`, go to an archive.
4. **Installation:**
   - `opkg`: the old sing-box package is removed (`--force-depends`), then podkop-engine is installed;
   - `apk`: `sing-box`, `sing-box-tiny` and `!podkop-engine` entries are removed from `/etc/apk/world`, then podkop-engine is installed in one transaction.

   Then podkop and its LuCI app are updated, `sing-box` autostart is disabled (podkop starts it), the `podkop-engine` failsafe service is enabled and podkop is started.
5. **Verification (up to 2 minutes):**
   - the sing-box process runs;
   - `fakeip.podkop.fyi` resolves into the FakeIP range;
   - regular DNS works;
   - a request through podkop's mixed inbound (`127.0.0.1:4534`) returns 204, if the proxy worked before installation.

   If any check fails, or on Ctrl+C during installation, the script rolls back automatically.

## Network behaviour

- **Timeout:** every `apk`/`opkg` network operation is limited to 90 s.
- **Package lists and repository installs** are tried in this order:
  1. `downloads.openwrt.org`;
  2. the `mirrors.cicku.me/openwrt` mirror (feeds are switched temporarily and restored right away, also on errors and Ctrl+C);
  3. podkop's HTTP proxy.

  `apk` / `opkg` verify package signatures themselves.
- **The rollback copy of sing-box** is downloaded only from `downloads.openwrt.org` (directly or via podkop), never from the mirror: on rollback it is installed from a local file without a signature check.
- **GitHub** (API and packages): via podkop's proxy if it works, otherwise directly; `wget` is used when `curl` is missing.

## Rollback

`sh pe.sh rollback`:
1. stops podkop — DNS and internet keep working without the proxy;
2. installs the saved sing-box package; without one, `sing-box-tiny` from the repository; during an installation run, the RAM copy of the sing-box files is the last resort;
3. restores `/etc/config/sing-box` and starts podkop.

podkop stays at the installed version: it works with the regular sing-box too.

## Files

| Path | Contents |
|---|---|
| `/root/podkop-engine-backup/config-*.tar.gz` | Settings backup |
| `/root/podkop-engine-backup/sing-box*.{ipk,apk}` | sing-box package for rollback (if there was enough flash; otherwise kept in `/tmp` until reboot) |
| `/root/podkop-engine-backup/install.log` | Log of the last run |
| `/tmp/podkop-engine-report.txt` | Last report |

## Report

`sh pe.sh report` collects:
- model, OpenWrt, podkop and sing-box versions;
- memory and flash;
- service states and listening ports;
- DNS and proxy checks;
- `uci show podkop` and `uci show sing-box`, dnsmasq settings;
- podkop and sing-box log;
- `podkop global_check`;
- the tail of the install log.

Proxy links, `outbound_json`, UUIDs, passwords, keys and short IDs are removed from the report. External IP and domain names from the logs remain.

## Limitations

- Only `aarch64_cortex-a53` is supported out of the box. `ENGINE_ARCH=<arch>` makes the script look for packages of another architecture in the latest releases; the built-in checksums cover `aarch64_cortex-a53` only, so `--pinned` and the offline fallback do not work for other architectures.
- The `podkop-engine` variant is installed (protocols used by podkop), not `podkop-engine-full`.
- The script does not configure podkop and does not check specific proxy servers.
