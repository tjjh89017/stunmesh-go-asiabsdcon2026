---
marp: true
theme: default
paginate: true
size: 16:9
style: |
  section {
    font-family: 'Inter', 'Source Han Sans', 'PingFang SC', sans-serif;
    color: #1F2937;
    background: #FFFFFF;
  }
  section.lead {
    text-align: center;
    background: #1e3a5f;
    color: #FFFFFF;
  }
  section.lead h1 {
    color: #FFFFFF;
  }
  section.lead h2 {
    color: #cbd5e1;
  }
  section.section-divider {
    text-align: center;
    background: #2563EB;
    color: #FFFFFF;
    display: flex;
    flex-direction: column;
    justify-content: center;
  }
  section.section-divider h1 {
    color: #FFFFFF;
    font-size: 52px;
  }
  section.section-divider p {
    color: #e0e7ff;
    font-size: 24px;
  }
  h1 { font-size: 36px; color: #1e3a5f; }
  h2 { font-size: 28px; color: #2563EB; }
  code { background: #f1f5f9; border-radius: 4px; }
  pre { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; }
  table { font-size: 18px; }
  th { background: #2563EB; color: #FFFFFF; }
  td { border: 1px solid #e2e8f0; }
  blockquote { border-left: 4px solid #2563EB; background: #eff6ff; padding: 12px 20px; }
  .red { color: #DC2626; }
  .blue { color: #2563EB; }
  .green { color: #16a34a; }
  .gray { color: #6b7280; }
  footer { font-size: 14px; color: #9ca3af; }
---

<!-- _class: lead -->

# Porting STUNMESH-go to FreeBSD and macOS
## Building Peer-to-Peer WireGuard Networks

**Yu-Chiang (Date) Huang**
Independent Researcher, Taiwan

AsiaBSDCon 2026

---

# About Me

- **Yu-Chiang (Date) Huang** — Independent Researcher, Taiwan
- Open-source developer focused on networking and system programming
- Author and maintainer of **STUNMESH-go**
  - WireGuard NAT traversal tool
  - Originally Linux-only → now runs on **FreeBSD** and macOS

<!-- 📧 tjjh89017@hotmail.com | 🔗 github.com/tjjh89017/stunmesh-go -->

---

# Agenda

1. **The Problem** — NAT/CGNAT blocks peer-to-peer WireGuard
2. **Background** — WireGuard, NAT types, STUN protocol
3. **STUNMESH-go** — Architecture and how it works on Linux
4. **Porting to FreeBSD** — What broke and why
5. **BSD-Specific Solutions** — BPF devices, packet capture, ICMP, wgctrl
6. **FreeBSD & OPNsense Testing** — Real-world validation
7. **Lessons for BSD Developers** — Cross-platform patterns in Go
8. **Future Work & Q&A**

---

# Why This Talk Matters for BSD

- **pfSense** and **OPNsense** run on FreeBSD
  - Thousands of enterprise and home firewall deployments
- WireGuard is now in the **FreeBSD kernel** (if-wg driver)
- But NAT traversal tools have been **Linux-only**
- This work brings **direct P2P WireGuard** to FreeBSD
  - No relay servers, no extra infrastructure
- Also: a case study in **porting Linux network code to BSD**

---

# Contributions of This Work

1. **Complete documentation** of how network programming differs between Linux, FreeBSD, and macOS — focusing on raw sockets, BPF, and ICMP
2. **Practical strategies** for writing portable network code in Go using platform-specific build tags and abstraction patterns
3. **Analysis of packet capture** across different link layer types and how it affects BPF filter design
4. **Testing results** on FreeBSD 14.3-RELEASE, OPNsense 25.1, and modern macOS
5. **Open-source code** available for the BSD community and network engineers

---

<!-- _class: section-divider -->

# 1. The Problem

NAT Blocks Peer-to-Peer VPN Connections

---

# NAT and CGNAT Are Everywhere

- **NAT** (Network Address Translation) conserves IPv4 addresses
- **CGNAT** (Carrier-Grade NAT) adds another layer at the ISP
- Both **block inbound connections** by default
- Peer-to-peer communication becomes impossible
  - Neither side can initiate a connection
  - Creates a "deadlock" situation

> NAT devices only allow inbound packets that match existing outbound connections.

<!-- IMAGE PROMPT: A diagram showing two computers behind separate NAT routers, with red X marks between them indicating they cannot reach each other directly. Show internal IPs being translated to external IPs. Simple, clean technical diagram, blue tones, 16:9. -->

---

# The WireGuard Challenge

- **WireGuard** is fast, secure, modern (~4,000 lines of code)
- But it assumes **at least one side has a stable endpoint**
- When **both peers are behind NAT**:
  - No stable public IP on either side
  - No way to start connections
- **Traditional fix:** relay servers
  - Added latency, bandwidth cost, single point of failure
  - Extra infrastructure to maintain

---

# This Matters for FreeBSD Firewalls

**Scenario:** Two OPNsense firewalls at remote sites

```
Site A                                     Site B
┌──────────┐                         ┌──────────┐
│ OPNsense │── CGNAT ──X──── CGNAT ──│ OPNsense │
│  (wg0)   │    ISP          ISP     │  (wg0)   │
└──────────┘                         └──────────┘
         Both behind NAT -> Can't connect!
```

- Both sites want a WireGuard tunnel
- Neither has a static public IP
- Without NAT traversal → need a relay server
- **STUNMESH-go solves this natively on FreeBSD**

---

<!-- _class: section-divider -->

# 2. Background

WireGuard, NAT Types, and STUN

---

# WireGuard on FreeBSD

- Kernel module: **if-wg** driver
  - Native kernel implementation
  - High performance, integrated with FreeBSD network stack
- Also available: **wireguard-go** (userspace)
- **Cryptographic primitives:**
  - Curve25519 (key exchange)
  - ChaCha20 (symmetric encryption)
  - Poly1305 (authentication)
- Managed via `wg(8)` and `wgctrl-go` library

---

# NAT Types and P2P Feasibility

| NAT Type | Behavior | P2P Friendly? |
|----------|----------|:-------------:|
| **Full-Cone** | Any host can reach mapped port | ✅ Best |
| **Restricted-Cone** | Only hosts you contacted can reply | ✅ Good |
| **Port-Restricted-Cone** | IP + port must match | ✅ Works |
| **Symmetric** | Different port per destination | ❌ Hard |

- Home routers: usually **Port-Restricted-Cone**
- CGNAT: usually **Port-Restricted-Cone**
- STUNMESH-go works with all cone types

---

# Full-Cone NAT

- Once mapped, **any** external host can send to the mapped port
- Most permissive — ideal for P2P

```
Internal 192.168.1.10:5000 → NAT → External 203.0.113.5:40000
                                          ↑
                              Any host can send here
```

---

# Restricted-Cone NAT

- NAT allows inbound only from hosts you **previously contacted**
- External host can reply from **any port**

```
Internal sends to 198.51.100.1 → NAT mapping created
198.51.100.1 (any port) → Allowed ✓
198.51.100.2 (any port) → Blocked ✗
```

---

# Port-Restricted-Cone NAT

- NAT checks **both** source IP **and** source port
- **Most common** type in home routers

```
Internal sends to 198.51.100.1:3478 → NAT mapping created
198.51.100.1:3478 → Allowed ✓
198.51.100.1:9999 → Blocked ✗ (wrong port)
198.51.100.2:3478 → Blocked ✗ (wrong IP)
```

---

# Symmetric NAT

- Different external port for **each destination**
- STUN server sees port X, but the peer needs port Y
- P2P very difficult → usually needs relay

```
Internal → dest A → NAT external port 40001
Internal → dest B → NAT external port 40002  (different!)
```

> Port discovered by STUN ≠ port the peer would need

---

# NAT Compatibility Matrix

|  | Full-Cone | Restricted | Port-Restricted | Symmetric |
|--|-----------|-----------|-----------------|-----------|
| **Full-Cone** | ✅ | ✅ | ✅ | ✅ |
| **Restricted** | ✅ | ✅ | ✅ | ⚠️ Maybe |
| **Port-Restricted** | ✅ | ✅ | ✅ | ❌ |
| **Symmetric** | ✅ | ⚠️ Maybe | ❌ | ❌ |

STUNMESH-go handles all ✅ cases — **no relay needed**.

---

# STUN Protocol (RFC 5389)

**Session Traversal Utilities for NAT** — endpoint discovery:

```
Client (192.168.1.10:5000)
   → NAT → (203.0.113.5:40000)
      → STUN Server (stun.example.com:3478)
         ← Response: "You are 203.0.113.5:40000"
```

1. Client sends **Binding Request** to STUN server
2. Server reads **source IP:port** after NAT translation
3. Server responds with observed public endpoint
4. Client now knows its external address
5. Peers **exchange** endpoints → direct connection

---

# Existing Solutions and Their Limitations

| | Tailscale | Netmaker | STUNMESH-go |
|-|-----------|---------|-------------|
| Kernel WireGuard | ❌ (embedded wg-go) | ✅ | ✅ |
| Coordination server | Required | Required (static IP) | **Not needed** |
| Relay fallback | DERP servers | N/A | None (P2P only) |
| FreeBSD support | Limited | Limited | **Full** |
| Port sharing | No | No | **Yes** |
| Overhead | Medium | Medium | **Low** |

STUNMESH-go: kernel WireGuard + same UDP port + no extra servers.

---

<!-- _class: section-divider -->

# 3. STUNMESH-go Architecture

How the Linux Version Works

---

# Architecture Overview

```
┌─────────────────────────────────────────────────┐
│                  STUNMESH-go                    │
│                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │
│  │Bootstrap │  │ Publish  │  │  Establish   │   │
│  │Controller│  │Controller│  │  Controller  │   │
│  └────┬─────┘  └────┬─────┘  └──────┬───────┘   │
│       │             │               │           │
│  ┌────┴─────┐  ┌────┴─────┐  ┌──────┴───────┐   │
│  │ WireGuard│  │  STUN    │  │   Storage    │   │
│  │  Config  │  │ Discovery│  │   Plugins    │   │
│  └──────────┘  └──────────┘  └──────────────┘   │
│                                                 │
│  ┌────────────────────────────────────────────┐ │
│  │       Refresh Controller + Ping Monitor    │ │
│  └────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

---

# The Four Controllers

| Controller | Role |
|-----------|------|
| **Bootstrap** | Init WireGuard devices, read config, map peers |
| **Publish** | STUN discovery → encrypt endpoint → store via plugin |
| **Establish** | Fetch peer endpoints → decrypt → configure WireGuard |
| **Refresh** | Periodic re-discovery + re-establishment |

Plus **Ping Monitor**: ICMP health checks through the tunnel.
When pings fail → triggers **Publish** (re-discover endpoint) + **Establish** (refresh peer config).

---

# The Key Innovation: UDP Port Sharing

STUNMESH-go shares **the same UDP port** as WireGuard:

```
          WireGuard Port (e.g., 51820/UDP)
                    │
         ┌──────────┴──────────┐
         │                     │
    WireGuard traffic      STUN traffic
    → kernel module        → raw socket + BPF
    (normal processing)    (captured by app)
```

- Raw IP socket intercepts STUN responses **before** kernel UDP stack
- BPF filter: check dest port + STUN magic cookie `0x2112A442`
- WireGuard traffic flows normally — **zero interference**
- No extra ports, no proxy layers

---

# Linux STUN Implementation

```go
// System-wide raw IP socket for UDP (protocol 17)
conn, err := net.ListenPacket("ip4:17", "0.0.0.0")

// Attach BPF filter — captures STUN on WireGuard port
conn.SetBPF(stunBpfFilter)
```

**This works because Linux raw sockets are system-wide:**
1. One socket → all interfaces
2. BPF attaches directly to the socket
3. Receives packets before kernel UDP stack
4. Simple, single capture loop

> But this Linux-specific design **completely breaks on FreeBSD**...

---

# Linux BPF Quirk: IPv4 vs IPv6 Asymmetry

A key detail in the Linux STUN implementation:

| | BPF sees | Offsets |
|-|----------|---------|
| **IPv4** | IP header + UDP header + payload | UDP port @ byte 22, cookie @ byte 32 |
| **IPv6** | UDP header + payload (IP stripped!) | UDP port @ byte 2, cookie @ byte 12 |

- **IPv4:** BPF filter runs **before** the kernel removes the IP header
- **IPv6:** BPF filter runs **after** the kernel removes the IP header
- Application code always receives **IP headers removed** for both

> Same raw socket, but BPF sees **different packet structures** per protocol!
> This asymmetry requires **separate BPF filter programs** for IPv4 and IPv6.

---

# Plugin Architecture

Flexible endpoint storage:

| Type | Communication | Example |
|------|--------------|---------|
| **Built-in** | Compiled into binary | Cloudflare DNS TXT |
| **Exec** | JSON over stdin/stdout | Custom API client |
| **Shell** | Variable-based protocol | Simple file/Redis |

```
Publish → Encrypt(endpoint, NaCl box) → Plugin.Store()
Establish → Plugin.Fetch() → Decrypt(endpoint) → wgctrl
```

Encryption: Curve25519 + XSalsa20 + Poly1305 (same keys as WireGuard).

---

<!-- _class: section-divider -->

# 4. Porting to FreeBSD

What Broke and Why

---

# Challenge Overview: Linux vs FreeBSD

| Area | Linux | FreeBSD |
|------|-------|---------|
| Packet capture | System-wide raw socket | Per-interface `/dev/bpf` |
| BPF attachment | Socket-level `SetBPF()` | Device-level `/dev/bpfN` |
| Link layer in BPF | IP level (no L2 header) | Full frame (Ethernet/Null) |
| ICMP binding | `SO_BINDTODEVICE` (VRF support) | Not needed (no VRF) |
| WireGuard API | `UpdateOnly` supported | `UpdateOnly` **not** supported |
| Build | `CGO_ENABLED=0` | `CGO_ENABLED=1` (required) |

**Every row** = a porting challenge we had to solve.

---

# Challenge #1: Raw Socket Model

## Linux — One socket captures all interfaces

```go
// System-wide — all interfaces, one socket, one BPF
conn, _ := net.ListenPacket("ip4:17", "0.0.0.0")
conn.SetBPF(filter)
// Done! One goroutine, one capture loop.
```

## FreeBSD — No system-wide raw sockets for this

- FreeBSD uses the classic **BSD Packet Filter** design
- Must open `/dev/bpf` **per interface**
- Must enumerate interfaces, filter eligible ones
- Must run **concurrent capture** across all interfaces

---

# BSD Packet Filter: The /dev/bpf Model

FreeBSD's BPF is the **original** BPF (McCanne & Jacobson, 1993):

```
Application
    ├── open(/dev/bpf0) → bind to em0  → set filter → read
    ├── open(/dev/bpf1) → bind to igb0 → set filter → read
    └── open(/dev/bpf2) → bind to vtnet0 → set filter → read
```

- Each `/dev/bpf` device binds to **one** interface
- Filter programs are per-device
- Packets include **full link layer frame**
  - Linux raw sockets strip L2 headers
  - FreeBSD BPF preserves them

> This is the **fundamental architectural difference**.

---

# Linux vs FreeBSD: Packet Capture Model

<!-- IMAGE PROMPT: Split comparison diagram. Left side "Linux": multiple interfaces (eth0, wlan0, eth1) all feeding into ONE funnel labeled "Raw Socket" with a single "BPF Filter". Right side "FreeBSD": each interface (em0, igb0, vtnet0) has its own separate /dev/bpf device with its own BPF filter. Blue color scheme, clean technical style, 16:9 presentation slide. -->

**Linux** — Centralized
- One raw socket → all interfaces
- One BPF filter program
- IP-level packets (no L2 header)

**FreeBSD** — Per-interface
- One `/dev/bpf` per interface
- Separate BPF filter per device
- Full frame with link layer header
- Multiple capture goroutines needed

---

# Consequences of the BSD Model (1/2)

**1. Interface Enumeration Required**
- Must discover all network interfaces at startup
- Must **exclude** the WireGuard interface (avoid self-capture)
- Must **exclude** link-down interfaces

**2. Multiple Concurrent Capture Loops**
- One goroutine per interface
- Read from multiple BPF devices simultaneously
- Channel-based synchronization for STUN responses

---

# Consequences of the BSD Model (2/2)

**3. Link Layer Headers Affect BPF Offsets**
- Ethernet interfaces: 14-byte header
- BSD loopback (Null): 4-byte header
- **Different offsets for the same logical fields!**

---

# Challenge #2: BPF Filter Offset Problem

BPF uses **absolute byte offsets** — the link layer changes everything:

```
Linux raw socket (no L2 header):
  [IP Header (20B)][UDP Header (8B)][STUN Payload]
   byte 0           byte 20          byte 28

FreeBSD Ethernet (/dev/bpf on em0):
  [Eth Header (14B)][IP Header (20B)][UDP Header (8B)][STUN]
   byte 0            byte 14          byte 34           byte 42

FreeBSD Null (/dev/bpf on lo0):
  [Null Header (4B)][IP Header (20B)][UDP Header (8B)][STUN]
   byte 0            byte 4           byte 24           byte 32
```

**Same BPF logic, completely different byte offsets!**

---

# BPF Offset Comparison: Where Is the STUN Magic Cookie?

| Context | UDP dst port | STUN cookie (0x2112A442) |
|---------|:----------:|:------------------------:|
| Linux raw IPv4 | byte 22 | byte 32 |
| Linux raw IPv6 | byte 2 | byte 12 |
| FreeBSD Ethernet IPv4 | byte 36 | byte 46 |
| FreeBSD Ethernet IPv6 | byte 56 | byte 66 |
| FreeBSD Null IPv4 | byte 26 | byte 36 |
| FreeBSD Null IPv6 | byte 46 | byte 56 |

- **6 different offset sets** across all combinations
- Must detect link type per-interface and build correct filter

---

# Challenge #3: Link Layer Type Detection

## Ethernet interfaces (em0, igb0, vtnet0)

```
[Dst MAC (6B)][Src MAC (6B)][EtherType (2B)][IP...][UDP...][Payload]
                              0x0800 = IPv4
                              0x86DD = IPv6
```

## BSD Loopback / Null (lo0, pppoe0)

```
[Protocol Family (4B)][IP Header...][UDP...][Payload]
 0x02000000 = IPv4
 0x18000000 = IPv6  ┐
 0x1C000000 = IPv6  ├── Three possible values!
 0x1E000000 = IPv6  ┘
```

> IPv6 on Null interfaces needs **three-way comparison** in BPF.

---

# Why Three IPv6 Values on BSD Null?

The 4-byte Null header stores the **address family**:

| Value (big-endian) | Meaning |
|:-------------------:|---------|
| `0x02000000` | AF_INET (IPv4) |
| `0x18000000` | AF_INET6 (24) |
| `0x1C000000` | AF_INET6 (28) — some BSDs |
| `0x1E000000` | AF_INET6 (30) — some BSDs |

- Different BSD variants use different AF_INET6 values
- Our BPF filter must handle **all three** to be portable
- Makes the Null IPv6 filter significantly more complex

---

# Challenge #4: ICMP Without SO_BINDTODEVICE (1/2)

## Linux: Bind ICMP to specific WireGuard interface

```go
syscall.SetsockoptString(fd,
    syscall.SOL_SOCKET,
    syscall.SO_BINDTODEVICE,
    "wg0")  // Pings ALWAYS go through wg0
```

## FreeBSD: No SO_BINDTODEVICE

```go
conn, _ := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
// deviceName parameter accepted but IGNORED
// Routing table determines which interface is used
```

---

# Challenge #4: ICMP Without SO_BINDTODEVICE (2/2)

- FreeBSD lacks VRF (Virtual Routing and Forwarding)
- Relies on the **routing table** to direct ICMP traffic
- Works in typical single-WAN setups
- Complex multi-interface scenarios may need extra routing rules

---

# ICMP Binding: Why Linux Needs SO_BINDTODEVICE

- Linux supports **VRF (Virtual Routing and Forwarding)** — multiple independent routing tables
- `SO_BINDTODEVICE` ensures the socket is bound to the correct VRF/routing table
- Without it, ICMP falls back to the **main routing table** instead of the VRF-specific one

## FreeBSD has no VRF

- Only one global routing table
- ICMP is routed by the system routing table — no need to bind to a specific interface
- Ping monitoring works correctly as long as the routing table has the correct entries

---

# Challenge #5: WireGuard API — UpdateOnly

Linux and macOS WireGuard support **atomic** peer endpoint updates:

```go
peerConfig.UpdateOnly = true  // ✅ Supported
```

FreeBSD's if-wg driver **does not** support UpdateOnly:

```go
peerConfig.UpdateOnly = false  // Must remove + re-add peer
```

- `wgctrl-go` returns error when UpdateOnly is set on FreeBSD
- Workaround: set `UpdateOnly = false` → library handles remove + re-add
- Brief connection interruption during re-add (acceptable for our use case)

---

# Challenge #6: CGO Requirement on FreeBSD

FreeBSD's `wgctrl-go` needs **CGO** to interact with the kernel WireGuard module:

```makefile
ifeq ($(GOOS),freebsd)
    CGO_ENABLED := 1    # Required for kernel wg interaction
else
    CGO_ENABLED := 0    # Static binary (Linux, macOS)
endif
```

| Platform | CGO | Why |
|----------|-----|-----|
| Linux | Off | Pure Go, static binary |
| macOS | Off | wireguard-go is pure Go |
| **FreeBSD** | **On** | Kernel module needs C FFI |

- Cross-compilation requires a C cross-compiler for FreeBSD targets
- GitHub Actions builds separate binaries per platform

---

<!-- _class: section-divider -->

# 5. BSD-Specific Solutions

How We Made It Work on FreeBSD

---

# Solution Strategy

**Goal:** Identical functionality, minimal code duplication

```
              ┌─── stun_linux.go     (raw socket + SetBPF)
stun API ─────┤
              └─── stun_bsd.go       (go-pcap + /dev/bpf)
                   //go:build freebsd || darwin

              ┌─── icmp_linux.go     (SO_BINDTODEVICE)
icmp API ─────┤
              └─── icmp_bsd.go       (routing-based)
                   //go:build freebsd || darwin

              ┌─── ctrl_linux.go     (UpdateOnly=true)
ctrl const ───┼─── ctrl_freebsd.go   (UpdateOnly=false)
              └─── ctrl_darwin.go    (UpdateOnly=true)
```

**Go build tags** select the right file at compile time.

---

# Go Build Tags: Platform-Specific Compilation (1/2)

```go
//go:build linux
package stun

// Linux: raw socket, system-wide BPF
func New(ctx context.Context, excludeInterface string,
    port uint16, protocol string) (*Stun, error) {
    conn, _ := net.ListenPacket("ip4:17", "0.0.0.0")
    // SetBPF(...)
}
```

---

# Go Build Tags: Platform-Specific Compilation (2/2)

```go
//go:build freebsd || darwin
package stun

// BSD: go-pcap, per-interface /dev/bpf
func New(ctx context.Context, excludeInterface string,
    port uint16, protocol string) (*Stun, error) {
    interfaces := getAllEligibleInterfaces(excludeInterface)
    // Open pcap handle for each interface...
}
```

---

# Common STUN Interface

Both platforms export **identical** API:

```go
type Stun struct {
    // Platform-specific internal fields (hidden)
}

func New(ctx context.Context,
    excludeInterface string,
    port uint16,
    protocol string) (*Stun, error)

func (s *Stun) Connect(ctx context.Context,
    stunAddr string) (string, int, error)

func (s *Stun) Start(ctx context.Context)
func (s *Stun) Stop() error
```

Application code is **completely platform-agnostic**.

---

# Solution: BSD Interface Enumeration

```go
func getAllEligibleInterfaces(
    excludeInterface string) ([]string, error) {
    interfaces, _ := net.Interfaces()

    var eligible []string
    for _, iface := range interfaces {
        // Skip loopback and down interfaces
        if iface.Flags&net.FlagLoopback != 0 || iface.Flags&net.FlagUp == 0 {
            continue
        }
        // Skip WireGuard interface (avoid self-capture!)
        if iface.Name == excludeInterface {
            continue
        }
        eligible = append(eligible, iface.Name)
    }
    return eligible, nil
}
```

---

# Solution: Per-Interface BPF Setup

For each eligible interface on FreeBSD:

```go
for _, ifaceName := range eligibleInterfaces {
    // 1. Open /dev/bpf for this interface
    handle, _ := pcap.OpenLive(ctx, ifaceName, PacketSize, false, timeout, pcap.DefaultSyscalls)

    // 2. Detect link layer type
    linkType := handle.LinkType()
    // → pcap.LinkTypeEthernet or pcap.LinkTypeNull

    // 3. Build BPF filter with CORRECT offsets
    filter := buildBPFFilter(linkType, port, protocol)
    handle.SetRawBPFFilter(filter)

    // 4. Calculate payload offset for STUN parsing
    payloadOff := calculatePayloadOffset(linkType, protocol)

    // 5. Store handle + metadata for capture loop
    s.handles = append(s.handles, interfaceHandle{...})
}
```

---

# Solution: Payload Offset Calculation

```go
func calculatePayloadOffset(linkType uint32,
    protocol string) uint32 {
    if linkType == pcap.LinkTypeNull {
        if protocol == "ipv6" {
            return 4 + 40 + 8   // Null(4) + IPv6(40) + UDP(8)
        }
        return 4 + 20 + 8       // Null(4) + IPv4(20) + UDP(8)
    }
    // Ethernet
    if protocol == "ipv6" {
        return 14 + 40 + 8      // Eth(14) + IPv6(40) + UDP(8)
    }
    return 14 + 20 + 8          // Eth(14) + IPv4(20) + UDP(8)
}
```

Each interface handle stores its own `payloadOff` → correct STUN message parsing regardless of link type.

---

# Solution: Ethernet IPv4 BPF Filter

```go
func stunEthernetBpfFilter(port uint16) []bpf.Instruction {
    return []bpf.Instruction{
        // Check IP protocol = UDP (17)
        // Offset: Eth(14) + IP protocol field(9) = byte 23
        bpf.LoadAbsolute{Off: 23, Size: 1},
        bpf.JumpIf{Val: 17, SkipFalse: 5},

        // Check UDP dst port = WireGuard port
        // Offset: Eth(14) + IP(20) + UDP dst(2) = byte 36
        bpf.LoadAbsolute{Off: 36, Size: 2},
        bpf.JumpIf{Val: uint32(port), SkipFalse: 3},

        // Check STUN magic cookie
        // Offset: Eth(14) + IP(20) + UDP(8) + cookie(4) = byte 46
        bpf.LoadAbsolute{Off: 46, Size: 4},
        bpf.JumpIf{Val: 0x2112A442, SkipFalse: 1},

        bpf.RetConstant{Val: 65535},  // Accept
        bpf.RetConstant{Val: 0},      // Reject
    }
}
```

---

# Solution: Ethernet IPv6 BPF Filter

```go
func stunEthernetIPv6BpfFilter(port uint16) []bpf.Instruction {
    return []bpf.Instruction{
        // Check EtherType == 0x86DD (IPv6)
        bpf.LoadAbsolute{Off: 12, Size: 2},
        bpf.JumpIf{Val: 0x86DD, SkipFalse: 7},

        // Check Next Header == 17 (UDP)
        // Offset: Eth(14) + IPv6 Next Header(6) = byte 20
        bpf.LoadAbsolute{Off: 20, Size: 1},
        bpf.JumpIf{Val: 17, SkipFalse: 5},

        // Check UDP dest port
        // Offset: Eth(14) + IPv6(40) + UDP dst(2) = byte 56
        bpf.LoadAbsolute{Off: 56, Size: 2},
        bpf.JumpIf{Val: uint32(port), SkipFalse: 3},

        // Check STUN magic cookie
        // Offset: Eth(14) + IPv6(40) + UDP(8) + cookie(4) = byte 66
        bpf.LoadAbsolute{Off: 66, Size: 4},
        bpf.JumpIf{Val: 0x2112A442, SkipFalse: 1},

        bpf.RetConstant{Val: 65535},
        bpf.RetConstant{Val: 0},
    }
}
```

---

# Solution: Null Loopback IPv6 BPF Filter

The most complex — **three-way protocol family check**:

```go
// Null header for IPv6 has 3 possible values:
bpf.LoadAbsolute{Off: 0, Size: 4},
bpf.JumpIf{Val: 0x18000000, SkipTrue: 2},   // AF_INET6 (24)
bpf.JumpIf{Val: 0x1C000000, SkipTrue: 1},   // AF_INET6 (28)
bpf.JumpIf{Val: 0x1E000000, SkipFalse: N},  // AF_INET6 (30)

// Then check UDP Next Header, port, and STUN cookie
// with Null(4) + IPv6(40) offsets...
```

vs. Null IPv4: just one check (`0x02000000`)
vs. Ethernet: just one check (`0x86DD`)

> Three-way branch makes the BPF bytecode **significantly larger**.

---

# BPF Filter Decision Tree

```
Packet arrives on interface
    │
    ├── What link type?
    │   ├── Ethernet (14B header)
    │   │   ├── IPv4: check EtherType 0x0800 → proto 17 → port → cookie
    │   │   └── IPv6: check EtherType 0x86DD → NH 17 → port → cookie
    │   │
    │   └── Null (4B header)
    │       ├── IPv4: check family 0x02000000 → proto 17 → port → cookie
    │       └── IPv6: check family 0x18/1C/1E → NH 17 → port → cookie
    │                          ↑
    │                  Three-way check!
    │
    └── Accept (STUN response) or Reject (everything else)
```

---

# Solution: Concurrent Packet Capture

```go
func (s *Stun) Start(ctx context.Context) {
    s.once.Do(func() {
        s.waitGroup.Add(len(s.handles))
        for _, ih := range s.handles {
            go func(handle interfaceHandle) {
                defer s.waitGroup.Done()
                defer handle.handle.Close()
                for {
                    select {
                    case <-ctx.Done():
                        return
                    default:
                        buf, _, err := handle.handle.ReadPacketData()
                        if err != nil { continue }
                        m := &stun.Message{
                            Raw: buf[handle.payloadOff:],
                        }
                        if err := m.Decode(); err != nil { continue }
                        s.packetChan <- m  // First response wins
                        return
                    }
                }
            }(ih)
        }
    })
}
```

---

# Concurrent Capture: How It Works

<!-- IMAGE PROMPT: Flow diagram showing three parallel goroutines (labeled em0, igb0, vtnet0) each reading from their own /dev/bpf device. Arrows from all three converge into a shared Go channel (packetChan). The channel connects to a "STUN Handler" box. Show the concurrent nature with parallel arrows. FreeBSD daemon logo in the corner. Clean technical diagram, blue and green, 16:9. -->

```
Goroutine (em0)    → /dev/bpf0 → Read → Decode ──┐
Goroutine (igb0)   → /dev/bpf1 → Read → Decode ──┼─→ packetChan
Goroutine (vtnet0) → /dev/bpf2 → Read → Decode ──┘       │
                                                    STUN Handler
```

- Each goroutine reads its own `/dev/bpf` device
- First to capture a valid STUN response sends it to the channel
- Others are cancelled via Go context
- `sync.Once` ensures Start() is only called once

---

# Solution: ICMP on FreeBSD

Common interface, different implementation:

```go
type ICMPConn struct { /* platform-specific */ }

func NewICMPConn(deviceName string) (*ICMPConn, error)
func (c *ICMPConn) Send(data []byte, addr net.Addr) error
func (c *ICMPConn) Recv(buf []byte, timeout time.Duration) (int, net.Addr, error)
func (c *ICMPConn) Close() error
```

```go
//go:build freebsd
func NewICMPConn(deviceName string) (*ICMPConn, error) {
    // deviceName is accepted but NOT used
    conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
    // Routing table determines interface
    return &ICMPConn{conn: conn}, err
}
```

---

# Solution: WireGuard UpdateOnly Constants

```go
//go:build freebsd
package ctrl
const UpdateOnly = false
// FreeBSD if-wg doesn't support UpdateOnly
// wgctrl falls back to remove + re-add peer
```

```go
//go:build linux
package ctrl
const UpdateOnly = true
```

```go
//go:build darwin
package ctrl
const UpdateOnly = true
```

One constant per platform — clean, no runtime checks.

---

# Solution: go-pcap Library

`github.com/packetcap/go-pcap` — pure Go BPF access for FreeBSD:

```go
// Open BPF device for interface
handle, err := pcap.OpenLive(ctx, "em0",
    PacketSize,           // snap length
    false,                // promiscuous mode
    timeout,              // read timeout
    pcap.DefaultSyscalls) // syscall interface

// Get link layer type for offset calculation
linkType := handle.LinkType()
// → pcap.LinkTypeNull or pcap.LinkTypeEthernet

// Set compiled BPF filter
handle.SetRawBPFFilter(rawInstructions)

// Read filtered packets
buf, captureInfo, err := handle.ReadPacketData()
```

No CGO needed for packet capture (CGO only for wgctrl).

---

# Complete BSD STUN Flow

```
1. getAllEligibleInterfaces("wg0")
   → [em0, igb0, vtnet0]

2. For each interface:
   a. pcap.OpenLive(ctx, iface, ...)
   b. Detect LinkType (Ethernet / Null)
   c. Build BPF filter with correct offsets
   d. Calculate payload offset

3. Start() → spawn goroutines per interface

4. Connect(stunAddr):
   a. Build raw UDP packet with STUN Binding Request
   b. Send via raw socket to STUN server
   c. Wait on packetChan for filtered STUN response
   d. Parse XOR-MAPPED-ADDRESS → return public IP:port

5. Stop() → cancel context, wait for goroutines
```

---

<!-- _class: section-divider -->

# 6. FreeBSD & OPNsense Testing

Real-World Validation

---

# Test Environments

| Platform | Version | WireGuard | Hardware |
|----------|---------|-----------|----------|
| **FreeBSD** | 14.3-RELEASE | Kernel (if-wg) | Physical + VM |
| **OPNsense** | 25.1 | Kernel (if-wg) | VM |
| macOS | Multiple | wireguard-go | Intel + Apple Silicon |
| Linux | Various | Kernel module | Servers, VyOS routers |

**Mixed environment:** VyOS + LTE modems + OPNsense + Linux + macOS

---

# Test Network Topology

<!-- IMAGE PROMPT: Network topology diagram for FreeBSD testing. Left: OPNsense firewall (FreeBSD-based) behind CGNAT from a mobile carrier. Right: Linux server behind home NAT router. Top center: STUN server in the cloud. Dotted lines show STUN discovery, solid green line shows established WireGuard P2P tunnel. Include FreeBSD daemon logo near OPNsense. Clean professional diagram, 16:9. -->

```
                    ┌─────────────┐
                    │ STUN Server │
                    │  (public)   │
                    └──────┬──────┘
              STUN         │         STUN
            discover       │       discover
         ┌─────────────────┼─────────────────┐
    ┌────┴────┐                         ┌────┴────┐
    │  CGNAT  │                         │Home NAT │
    │(carrier)│                         │(router) │
    └────┬────┘                         └────┬────┘
    ┌────┴────┐                         ┌────┴────┐
    │OPNsense │◄══════ WireGuard ══════►│  Linux  │
    │FreeBSD  │      P2P Tunnel         │ Server  │
    │  (wg0)  │                         │  (wg0)  │
    └─────────┘                         └─────────┘
```

---

# FreeBSD 14.3-RELEASE Results (1/2)

**Basic connectivity:** ✅
- STUN discovery correctly identifies public endpoint
- Endpoint encrypted and stored (Cloudflare DNS TXT)
- WireGuard tunnel established automatically

**BPF filter correctness:** ✅
- Tested on Ethernet (em0, igb0) and virtual (vtnet0) interfaces
- Correct offset calculations for both IPv4 and IPv6

---

# FreeBSD 14.3-RELEASE Results (2/2)

**Kernel WireGuard (if-wg):** ✅
- `UpdateOnly=false` workaround functions correctly
- Peer endpoints updated via remove + re-add
- Brief interruption acceptable (sub-second)

---

# OPNsense 25.1 Results

OPNsense has **multiple interfaces** — a critical test:

| Test | Result |
|------|--------|
| WireGuard interface excluded from STUN | ✅ |
| STUN response captured on WAN interface | ✅ |
| Interface up/down handled gracefully | ✅ |
| Multi-WAN correct interface selection | ✅ |
| Ping monitoring through wg0 tunnel | ✅ |
| Automatic recovery after WAN disconnect | ✅ |

> OPNsense is the **primary target deployment** for STUNMESH-go on FreeBSD.

---

# Link Layer Variation Tests (FreeBSD)

| Interface | Type | Header Size | BPF Filter | Result |
|-----------|------|:-----------:|-----------|:------:|
| em0 | Ethernet | 14 bytes | Ethernet filter | ✅ |
| igb0 | Ethernet | 14 bytes | Ethernet filter | ✅ |
| vtnet0 | Virtual Ethernet | 14 bytes | Ethernet filter | ✅ |
| lo0 | Loopback | 4 bytes (Null) | Null filter | ✅ |

- Packet captures confirmed correct STUN matching per link type
- Offset calculations verified with `tcpdump` cross-reference

---

# NAT Type Coverage Results

| NAT Configuration | Expected | Result |
|-------------------|----------|:------:|
| Full-Cone ↔ Full-Cone | Direct P2P | ✅ |
| Full-Cone ↔ Port-Restricted | After handshake | ✅ |
| Port-Restricted ↔ Port-Restricted | After handshake | ✅ |
| Full-Cone ↔ Symmetric | Full-Cone accepts | ✅ |
| Restricted ↔ Symmetric | Maybe | ⚠️ |
| Port-Restricted ↔ Symmetric | Port mismatch | ❌ |
| Symmetric ↔ Symmetric | Need relay | ❌ |

All cone-type combinations work on FreeBSD — matches Linux behavior.

---

# Ping Monitoring Validation

| Test | Result |
|------|:------:|
| ICMP Echo through wg0 tunnel | ✅ |
| WAN disconnect detection | ✅ |
| UDP port block detection | ✅ |
| Auto re-discovery after restore | ✅ |
| Adaptive backoff (2s, 2s, 2s, 5s, 10s...) | ✅ |

```
Normal ── Normal ── FAIL! ── Retry 2s ── Retry 2s ── Retry 2s
                                                          │
    Retry 5s ── Retry 10s ── Network restored! ── Re-STUN │
                                                          │
                              Tunnel re-established ◄─────┘
```

---

<!-- _class: section-divider -->

# 7. Lessons for BSD Developers

Cross-Platform Network Programming in Go

---

# Lesson 1: Abstract Early, Abstract at the Right Level

```
                 Application Layer
                      │
              ┌───────┴───────┐
              │ Common API    │ ← New(), Connect(), Start(), Stop()
              ├───────┬───────┤
              │ Linux │  BSD  │ ← Platform-specific implementations
              └───────┴───────┘
```

- Define the interface **first**, then implement per-platform
- Go interfaces + build tags = clean separation
- Application code never knows which platform it's on
- Test the interface contract, not the implementation

---

# Lesson 2: BSD's BPF Is More Faithful to the Original

- Linux adapted BPF into **socket filters** (and later eBPF)
- FreeBSD preserves the **original device-based BPF** design

| Aspect | Linux (adapted) | FreeBSD (original) |
|--------|----------------|-------------------|
| Scope | System-wide socket | Per-interface device |
| Headers | IP-level | Full frame |
| Simplicity | Simpler for apps | More explicit control |
| Flexibility | Less granular | Per-interface filters |

> Understanding BSD's BPF model is essential for network tool portability.

---

# Lesson 3: Link Layers Are Not Just "Ethernet"

```
Common mistake: hardcoding Ethernet header = 14 bytes

Reality on FreeBSD:
  em0    → Ethernet (14B)
  vtnet0 → Ethernet (14B)
  lo0    → Null (4B)         ← Different!
  gif0   → Null (4B)         ← Different!
  tun0   → Null or none      ← Different!
```

**Always check `LinkType()` per interface!**
- Use `pcap.LinkTypeNull` vs `pcap.LinkTypeEthernet`
- Calculate offsets dynamically, never hardcode
- Test on loopback too (not just physical NICs)

---

# Lesson 4: Don't Assume Linux Socket Options Exist

**Linux-specific socket options used in network tools:**

| Option | Linux | FreeBSD | Workaround |
|--------|:-----:|:-------:|------------|
| `SO_BINDTODEVICE` | ✅ | ❌ | Use routing table |
| `IP_TRANSPARENT` | ✅ | ❌ | `ipfw` / `pf` rules |
| `SO_REUSEPORT` (with BPF) | ✅ | Partial | Redesign |
| Raw IP socket (system-wide) | ✅ | ❌ | Use `/dev/bpf` |

> When porting from Linux: **audit every socket option** against FreeBSD `man` pages.

---

# Lesson 5: Go Build Tags Are Your Best Friend

```go
//go:build freebsd
// FreeBSD-specific code

//go:build linux
// Linux-specific code

//go:build freebsd || darwin
// All BSD-family (shared implementation)

//go:build !linux
// Everything except Linux
```

- Compile-time selection — no runtime overhead
- Keep platform code in **separate files**
- Share code between FreeBSD and macOS where possible
- Use constants (not functions) for simple platform differences

---

# Lesson 6: Test on Real FreeBSD, Not Just VMs

**Issues only found on real hardware:**
- NIC driver differences (em vs igb vs vtnet)
- Timing variations in BPF reads
- Interface naming conventions

**Issues found on OPNsense specifically:**
- Multi-interface filtering (WAN, LAN, DMZ)
- Interface state changes during operation
- Firewall rules interacting with raw packet capture

> Virtual machines catch most issues, but real deployments reveal edge cases.

---

<!-- _class: section-divider -->

# 8. Discussion & Future Work

---

# Current Limitations

| Limitation | Impact | Potential Fix |
|-----------|--------|---------------|
| No `SO_BINDTODEVICE` on BSD | ICMP routing depends on table | VRF support (future FreeBSD?) |
| Single STUN server | No failover | Multi-server with health check |
| IPv4-only ping monitoring | Can't check IPv6 tunnels | ICMPv6 support (needs work) |
| FreeBSD `UpdateOnly` | Brief reconnection | Future if-wg kernel patch |
| `wgctrl-go` requires CGO | No static binary on FreeBSD | Pure-Go wgctrl implementation |

---

# FreeBSD Platform Support Summary

| Feature | Status | Notes |
|---------|:------:|-------|
| STUN Discovery (IPv4) | ✅ | go-pcap + /dev/bpf |
| STUN Discovery (IPv6) | ✅ | EtherType + Null checks |
| Kernel WireGuard (if-wg) | ✅ | CGO required |
| Userspace WireGuard (wg-go) | ✅ | Pure Go |
| Ping Monitoring | ✅ | Routing-based |
| Multi-interface | ✅ | Per-interface BPF |
| OPNsense deployment | ✅ | Tested on 25.1 |
| pfSense deployment | ⚠️ | Untested (FreeBSD base, expected to work) |
| Static binary | ⚠️ | C libs statically linked via CGO |

---

<!-- _class: section-divider -->

# Conclusion

---

# Key Takeaways

1. **STUNMESH-go now runs on FreeBSD** — enabling direct P2P WireGuard on pfSense/OPNsense without relay servers

2. **BSD's BPF model is fundamentally different** from Linux raw sockets — per-interface, full-frame, device-based

3. **Link layer awareness is critical** — Ethernet vs Null headers change all BPF offsets

4. **Go build tags + interface abstractions** = clean cross-platform code with no runtime cost

5. **FreeBSD-specific quirks** (no UpdateOnly, CGO required, no SO_BINDTODEVICE) are all workable with proper design

6. **Tested on real FreeBSD 14.3 and OPNsense 25.1** — production-ready

---

# Get the Code

## github.com/tjjh89017/stunmesh-go

- **License:** GPLv2 or later
- **Language:** Go
- **FreeBSD:** amd64, arm64 (CGO enabled)
- **Also:** Linux (amd64/arm/arm64/mipsle), macOS (amd64/arm64)

```bash
# On FreeBSD / OPNsense:
pkg install wireguard-tools
# Download stunmesh-go binary for freebsd-amd64
# Configure stunmesh.toml with your WireGuard interface
# Run stunmesh-go — direct P2P connections established!
```

**Contributions welcome** — especially from FreeBSD kernel/networking developers!

---

<!-- _class: lead -->

# Thank You!

## Questions?

**Yu-Chiang (Date) Huang**
tjjh89017@hotmail.com
github.com/tjjh89017/stunmesh-go

AsiaBSDCon 2026

---

<!-- _class: section-divider -->

# Backup Slides

Additional Technical Details

---

# Backup: STUN Message Structure

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|0 0|     STUN Message Type     |         Message Length        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Magic Cookie (0x2112A442)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                  Transaction ID (96 bits)                     |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Magic Cookie `0x2112A442` — the key field our BPF filter targets to distinguish STUN from WireGuard traffic on the same port.

---

# Backup: NaCl Box Endpoint Encryption

```
Peer A public key ──┐
                    ├──→ Shared secret ──→ Encrypt(endpoint)
Peer B private key ─┘

    Encrypted endpoint → Plugin.Store() (e.g., DNS TXT)

Peer B public key ──┐
                    ├──→ Shared secret ──→ Decrypt(endpoint)
Peer A private key ─┘
```

- Reuses WireGuard's own Curve25519 public keys
- NaCl box: Curve25519 + XSalsa20 + Poly1305
- Safe to store in public DNS/Redis/API

---

# Backup: Complete BPF Filter Flow on FreeBSD

```
Packet arrives at em0 (Ethernet)
         │
    ┌────┴─────┐
    │ Ethernet │  14 bytes: [DstMAC][SrcMAC][EtherType]
    │  Header  │  Check: 0x0800 (IPv4) or 0x86DD (IPv6)
    └────┬─────┘
         │
    ┌────┴─────┐
    │ IP Header│  20 bytes (IPv4) or 40 bytes (IPv6)
    │          │  Check: protocol/NH = 17 (UDP)
    └────┬─────┘
         │
    ┌────┴─────┐
    │UDP Header│  8 bytes
    │          │  Check: dst port = WireGuard port
    └────┬─────┘
         │
    ┌────┴─────┐
    │ Payload  │  Check: bytes 4-7 = 0x2112A442 (STUN cookie)
    └────┬─────┘
         │
    Accept ✓ → packetChan → STUN Handler
```

---

# Backup: Adaptive Retry Timeline

```
Time →

Ping OK ── OK ── OK ── FAIL!
                         │
                    ┌────┘
                    ▼
               Retry 1 (2s) ── FAIL
               Retry 2 (2s) ── FAIL
               Retry 3 (2s) ── FAIL    (fixed phase: quick recovery)
               Retry 4 (5s) ── FAIL
               Retry 5 (10s) ─ FAIL    (backoff phase)
               Retry 6 (15s) ─ Network restored!
                    │
                    ▼
          STUN re-discovery
          WireGuard re-establish
                    │
                    ▼
               Ping OK ── OK ── OK ──→  (normal operation)
```

---

# Backup: macOS Notes

macOS is also BSD-based and shares the FreeBSD implementation:

- Uses the **same** `stun_bsd.go` (build tag: `darwin || freebsd`)
- Uses **wireguard-go** (userspace, not kernel)
- `UpdateOnly = true` (same as Linux)
- `CGO_ENABLED = 0` (no kernel wg interaction needed)
- Primary role: **development and testing** platform
- Developers can test STUNMESH-go on macOS before deploying to FreeBSD

---

# Backup: Cross-Compilation Matrix

| Target | GOOS | GOARCH | CGO | Binary |
|--------|------|--------|:---:|--------|
| Linux x86_64 | linux | amd64 | 0 | Static |
| Linux ARM | linux | arm | 0 | Static |
| Linux ARM64 | linux | arm64 | 0 | Static |
| Linux MIPS | linux | mipsle | 0 | Static |
| **FreeBSD x86_64** | **freebsd** | **amd64** | **1** | **Static (C libs linked)** |
| **FreeBSD ARM64** | **freebsd** | **arm64** | **1** | **Static (C libs linked)** |
| macOS x86_64 | darwin | amd64 | 0 | Static |
| macOS ARM64 | darwin | arm64 | 0 | Static |
