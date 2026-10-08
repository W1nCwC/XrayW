[简体中文](docs/README.zh-CN.md)

# XrayW

> XrayW is an XrayR rewrite (reset edition) built on the official Xray-core, designed for Xboard. It was first developed as W1nCray v0.1–v0.3; W1nCray has since evolved into a multi-core agent, see https://github.com/W1nCwC/W1nCray

A node backend for [Xboard](https://github.com/cedar2025/Xboard), rebuilt from XrayR on the **official stable Xray-core (v26.3.27)**.

- Current version: **v1.0.0** (Xray-core v26.3.27)
- Kernel: the official `github.com/xtls/xray-core v1.260327.0` (= v26.3.27, the latest non-prerelease version as of 2026-10). No modified forks are used.
- Configuration: keeps the XrayR `config.yml` structure, so existing configs mostly work as they are.
- Panel: connects to the Xboard UniProxy node API (`/api/v1/server/UniProxy/*`).

## Comparison with XrayR

| Capability | XrayR v0.9.4 (NewV2board) | XrayW |
|---|---|---|
| Xray core | v1.8.20 (2024) | v26.3.27 |
| Panel `device_limit` | Not implemented (`todo` in the code) | ✅ Real-time per node, plus a cross-node global limit using Xboard `alivelist` |
| Online IP reporting (`alive`) | Not implemented | ✅ |
| Node load reporting (`status`) | Not implemented | ✅ CPU / memory / swap / disk |
| User speed limit | Large packets can bypass it (`WaitN` with n > burst passes straight through) | ✅ Fixed. Independent upload and download token buckets; splice is disabled under Vision to prevent bypass |
| Hysteria2 | ❌ | ✅ (including salamander obfuscation and bandwidth) |
| XHTTP / VLESS Encryption / ECH | ❌ | ✅ |
| Panel certificate delivery `cert_config` | ❌ | ✅ http / dns / self / file / content |
| Panel custom outbounds / custom routing | ❌ | ✅ |
| Access to internal addresses blocked by default | ❌ | ✅ (can be turned off) |
| Dispatcher implementation | Copied and modified official code | Wraps the official DefaultDispatcher (easier to follow kernel upgrades) |

## Protocol Support

| Xboard node type | Support |
|---|---|
| VMess | ✅ TCP / WS / gRPC / HTTPUpgrade / XHTTP / mKCP, optional TLS |
| VLESS | ✅ Same as above, plus REALITY, `xtls-rprx-vision`, VLESS Encryption |
| Trojan | ✅ TLS or REALITY |
| Shadowsocks | ✅ AEAD (aes-128/256-gcm, chacha20-poly1305, etc.), 2022-blake3-aes-128/256-gcm |
| Hysteria2 | ✅ |
| SOCKS / HTTP | ✅ (the inbound is rebuilt when users change) |
| Shadowsocks 2022-chacha20 | ❌ Not supported by Xray multi-user |
| Hysteria v1 / TUIC / AnyTLS / Naive / Mieru | ❌ No matching inbound in official Xray; startup reports an error |
| Transport H2 / QUIC | ❌ Removed by Xray; use XHTTP instead |

## Installation (Linux: Debian/Ubuntu, Alpine, OpenWRT, etc.)

Supports three service managers: systemd (Debian/Ubuntu/CentOS, etc.), OpenRC (Alpine), and procd (OpenWRT). The script is POSIX sh and only depends on tools that busybox provides.

```bash
# One-line install (use either curl or wget; OpenWRT has no curl, so use wget)
(curl -fsSL -o /tmp/XrayW-install.sh https://raw.githubusercontent.com/W1nCwC/XrayW/main/install.sh \
  || wget -O /tmp/XrayW-install.sh https://raw.githubusercontent.com/W1nCwC/XrayW/main/install.sh) \
  && sh /tmp/XrayW-install.sh install
# Or use a locally built binary
sh install.sh install --binary ./XrayW-linux-amd64
```

Install options: `--lite | --full` (build flavor), `--prefix DIR` (install directory; point it at external storage when space is short), `--with-geo` (force the geo files to be downloaded), `--version vX.Y.Z`, `--url URL`, `--binary FILE`.

The install script will:

1. Pick the asset that matches the CPU (amd64 / 386 / arm64 / armv5-7 / mips / mipsle / mips64(le) / riscv64 / loong64). MIPS byte order is read from the ELF header and ARM VFP support from `/proc/cpuinfo`. If the self-check of the binary fails, it falls back to a build with lower requirements. The download is verified against `SHA256SUMS`.
2. Install to `/usr/local/XrayW/XrayW`, use `/etc/XrayW` as the config directory, register the service `XrayW`, and place the management command at `/usr/local/bin/XrayW` (`/usr/bin/XrayW` on OpenWRT).
3. **Automatically migrate when `/etc/XrayR/config.yml` is found**: `config.yml`, the dns/route/inbound/outbound/rule lists, the geo files, and the certificates XrayR has already issued. XrayR's files are only read and are never modified. Without XrayR, a default config is generated.
4. Download `geoip.dat` / `geosite.dat` when they are missing (OpenWRT does not download them by default because they are about 27 MB; add `--with-geo` if you need them).
5. Run `XrayW check --online`: fetch every node from the panel and build its inbound for real, without listening on any port.
6. **XrayW will not start while XrayR is still running** (the ports would conflict). Switch over after you have confirmed the setup.

### Management commands (type `XrayW` after installation)

```bash
XrayW                      # Management menu
XrayW status               # Version, running state, start on boot, node count, recent errors
XrayW log [-n 100]         # Live logs (-n shows only the last N lines)
XrayW check                # Check the config and verify each node with the panel
XrayW start|stop|restart   # Service control
XrayW enable|disable       # Start on boot
XrayW config               # Edit the config; you can check it right after saving
XrayW update [vX.Y.Z] [--lite|--full]
XrayW switch               # Disable XrayR and enable XrayW; rolls back automatically if it is not running normally within 5 seconds
XrayW rollback             # Go back to XrayR at any time
XrayW migrate              # Migrate again (the existing /etc/XrayW is first backed up to /etc/XrayW.bak.<timestamp>)
XrayW uninstall [--purge]  # Uninstall (--purge also deletes the config)
```

Other subcommands (`version`, `x25519`, `init`, and `migrate` / `check` with arguments, etc.) are passed unchanged to the program itself.

### Alpine / OpenWRT notes

- **Alpine**: supervised by OpenRC's `supervise-daemon`. After a crash it restarts every 10 seconds, with no limit. Logs go to `/var/log/XrayW.log`.
- **OpenWRT**: supervised by procd (`respawn 3600 10 0`). Logs are read with `logread -e XrayW`. The default install is the lite build (`-lite`, about 39 MB; its ACME DNS validation covers only alidns / cloudflare / dnspod / godaddy / namesilo / tencentcloud). `GOMEMLIMIT` is set automatically when RAM is below 1 GiB. A router's built-in flash usually cannot hold the binary, so mount external storage (extroot or USB/SD) and install with `--prefix /mnt/xxx/XrayW`. The config and service scripts are added to `/etc/sysupgrade.conf`, so the config survives a firmware upgrade, but the program files must be reinstalled by running the install command again.
- If a DNS provider is missing from the lite build, run `XrayW update --full` to switch to the full build.
- Only one XrayW instance may run for the same config at a time (`<config file>.lock`). This prevents several processes from kicking each other off the panel WebSocket.
- When migrating from XrayR, old inbound tags in the routing (such as `V2ray_0.0.0.0_65534`) are mapped automatically to the matching node inbounds, so `route.json` does not need to be edited.

### Commands (the program itself)

```bash
XrayW -c /etc/XrayW/config.yml                     # Run
XrayW migrate --from /etc/XrayR --to /etc/XrayW    # Migrate XrayR (--dry-run only previews, --force overwrites)
XrayW check -c /etc/XrayW/config.yml [--online]    # Check the config (--online also verifies nodes with the panel)
XrayW init --dir /etc/XrayW                        # Write the default config
XrayW version                                      # Version, kernel version and build flavor (full / lite)
XrayW x25519                                       # Generate a REALITY key pair
```

When panel routes use `geosite:` / `geoip:`, `geosite.dat` and `geoip.dat` are required. They are looked up in the config file's directory by default, or you can set the `XRAY_LOCATION_ASSET` environment variable to point elsewhere.

### Build and release

```bash
bash release/build.sh v1.0.0 [arch ...]   # Default: 12 architectures × full/lite; produces .gz files and SHA256SUMS
```

Outputs: `XrayW-linux-<arch>.gz` and `XrayW-linux-<arch>-lite.gz`. Uncompressed copies are no longer produced. Upload every file in `dist/` to a GitHub Release. Lite build tags: `dnslite,fallbackroots`.

## Configuration

For a full example, see [release/config/config.yml.example](release/config/config.yml.example). Minimal config:

```yaml
Log:
  Level: warning
Nodes:
  - PanelType: Xboard
    ApiConfig:
      ApiHost: "https://xboard.example.com"
      ApiKey: "communication key"
      NodeID: 1
```

After you change the config file (or the dns/route/inbound/outbound/rule files it references), it reloads automatically.

### Migrating from XrayR

We recommend migrating with the install script or `XrayW migrate`. Either one prints every step it takes. Conversion rules:

| XrayR | XrayW |
|---|---|
| `/etc/XrayR/...` paths (including paths in comments) | `/etc/XrayW/...`. Referenced files are copied along with the config. Paths outside the XrayR directory are kept and a warning is shown |
| `PanelType: NewV2board / V2board` | `Xboard`. Nodes for other panels such as SSpanel are removed, with a warning |
| `NodeType: V2ray` + `EnableVless: true` | `NodeType: vless` (matches the node_type XrayR sends to the panel). EnableVless and VlessFlow are deleted |
| `DisableLocalREALITYConfig: true` | `EnableREALITY: false` (use the panel REALITY) |
| `DisableIVCheck`, `GlobalDeviceLimitConfig` | Deleted. The latter is replaced by Xboard's built-in cross-node device statistics, so Redis is not needed |
| ACME certificates issued by XrayR (`cert/certificates/<domain>.crt`) | Copied to the XrayW certificate path. Not re-issued |
| dns.json / route.json / custom_*.json / rulelist | Copied as they are, then checked entry by entry with the new kernel. Incompatible items are reported with the file name and entry number |

Things to note after migrating:

- XrayR uses the panel's REALITY settings only when `DisableLocalREALITYConfig: true`. XrayW uses the panel REALITY directly when the panel node has `tls=2`.
- `SendIP: 0.0.0.0` now means the system chooses the outbound address. XrayR bound to IPv4, which made IPv6 destinations unreachable.
- Xray v26 has removed `allowInsecure` from custom outbounds; use `pinnedPeerCertSha256` instead.

### Panel WebSocket (real-time sync)

When WebSocket is enabled for the node in Xboard (a switch in the admin panel, plus running `ws-server`), XrayW discovers and connects automatically through `/api/v2/server/handshake`. No configuration is needed:

- User add / ban / over-traffic / expiry, and node configuration changes: **take effect within seconds** (no longer waiting for `pull_interval`).
- Online IPs are **reported in real time**. A new IP is reported within about 1 second of connecting. After a disconnect, the IP is reported as offline 30 seconds later; this grace period keeps short connections from making the online count flap. If nothing has changed, the state is refreshed every 60 seconds. XrayW also receives the device IPs for the whole network from the panel, so cross-node device limits are counted the same way Xboard counts them.
- Without WebSocket, online IPs are still reported in real time over HTTP (interval ≥ 5 seconds). However, Xboard's HTTP API cannot express "offline", so an offline IP stays until the panel expires it after 300 seconds.
- Traffic and load are still reported over HTTP. HTTP polling is always kept as a fallback. When WebSocket disconnects, it reconnects automatically and the node keeps running normally in the meantime.
- To disable it, set `ControllerConfig.DisableWebSocket: true`.

Panel side: if Xboard uses a custom compose file that overrides the startup command with `octane:start`, the built-in Caddy and ws-server will not start. Run `php artisan ws-server start` separately and reverse-proxy `/ws` to it in Nginx (`proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade";`).

### Routing and behavior notes

- **Route order**: node security rules (internal address blocking) → panel routes / custom routes / local RuleList → global `route.json` → node fallback outbound. All node rules apply only to that node's inbound, so they do not affect each other.
- **Panel route match**: domains are matched as written in the Xboard admin panel, such as `example.com` and `*.example.com`, which cover the domain and its subdomains. Xray native prefixes (`domain:`, `full:`, `regexp:`, `geosite:`, `geoip:`, etc.) and IP/CIDR are also supported. Entries that contain regex special characters are treated as regular expressions, for compatibility with XrayR-era configs.
- **proxy action**: `action_value` is a tag from the node's `custom_outbounds` on the panel, or a tag in the local `custom_outbound.json`.
- **dns action**: takes effect as an Xray DNS server. Changing a DNS route on the panel triggers a full reload.
- **custom_outbounds / custom_routes**: interpreted as native Xray outbound and routing-rule JSON. The Xboard-Node format `{tag, protocol, settings, proxy_tag}` is also accepted.
- **Certificates**: when a node delivers `cert_config`, the panel config is used first. Otherwise the local `CertConfig` is used. Xray reloads certificate files every hour, and they are renewed automatically 30 days before expiry.
- **Speed limit**: the panel's `speed_limit` (Mbps) applies to each user's upload and download on this node, and each direction is calculated independently. A local `SpeedLimit > 0` overrides the panel value.
- **Device count**: the number of distinct source IPs a user has on this node, plus the devices Xboard counts on other nodes. New IPs are rejected when the total exceeds `device_limit`.

## Known Limitations

- REALITY: after each start, the first handshake to a given target waits about 5 seconds. The Xray REALITY library probes the target's handshake characteristics; this is upstream behavior.
- mKCP: Xray v26 moved header/seed into finalmask. XrayW converts them automatically, but compatibility with older clients has not been tested.
- Xray v26 **clients** have removed `allowInsecure` (replaced by `pinnedPeerCertSha256`). When you use a self-signed certificate (`cert_mode: self`), newer clients must be configured with the certificate fingerprint.
- All nodes run in the same Xray instance, so they share the DNS and global routing configuration.

## Development

```bash
go test ./...            # Unit tests and end-to-end tests (real Xray clients through each protocol proxy)
go run ./tools/protogen  # Regenerate app/dispatcher/config.pb.go (no protoc needed)
sh tests/install_test.sh # Install script tests (works with dash, busybox ash and bash; does not touch the system)
go test -tags dnslite,fallbackroots ./common/cert/ ./core/ # Lite build
```

Design and verification notes: [docs/PLAN.md](docs/PLAN.md), [docs/PLAN-v2-migration.md](docs/PLAN-v2-migration.md).

## License

[MPL-2.0](LICENSE). This project follows the design and configuration format of XrayR (MPL-2.0) and is built on Xray-core (MPL-2.0). `migrate/testdata/xrayr-v0.9.4/` contains the original XrayR sample files, which are used only as migration test fixtures.
