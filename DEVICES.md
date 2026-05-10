# New Virtio Device Backends

Add three new virtio device backends: virtio-rng, virtio-snd, and virtio-net.
Each follows the existing `VirtioDeviceBackend` protocol pattern (see
`VirtioMMIO.swift`). Use `VirtioBlock.swift` and `VirtioInput.swift` as
reference implementations.

Do virtio-rng first (simplest, validates understanding of the pattern), then
virtio-snd (medium complexity), then virtio-net (most complex due to
vmnet.framework).

## Slot Assignments

Current: 0=9p, 1=input-kb, 2=input-tablet, 3=metal, 4=blk. New: **5=virtio-snd,
6=virtio-net, 7=virtio-rng.**

Update the comment at the top of `main.swift` to document all 8 slots.

---

## 1. virtio-rng (VirtioRng.swift) — Slot 7

The simplest possible virtio device.

- **Device ID:** 4 (virtio spec §5.4)
- **Features:** none (0)
- **Queues:** 1 (requestq)
- **Config space:** none
- **No CLI flag** — always present (tiny, harmless)

### Behavior

Guest posts writable buffers to queue 0. On `handleNotify`, pop each available
buffer, fill it with random bytes via `SecRandomCopyBytes` (Security.framework),
push to used ring with `bytesWritten` = buffer length, raise interrupt.

### Build

Add `import Security` in the file. Link Security.framework in `Package.swift`.

---

## 2. virtio-snd (VirtioSound.swift) — Slot 5

Full audio I/O backed by Core Audio using raw AudioUnit (AudioToolbox) — not
AVAudioEngine. Minimum latency: target 256-frame buffer (~5ms at 48 kHz).

- **Device ID:** 25 (virtio spec §5.14)
- **Features:** none (feature bits are reserved in current spec)
- **Queues:** 4 (controlq=0, eventq=1, txq=2, rxq=3) — all functional
- **CLI flag:** `--audio` (optional, off by default). When absent, don't
  register slot 5.

### Config Space (virtio_snd_config, spec §5.14.4)

| Offset | Field   | Type | Value |
| ------ | ------- | ---- | ----- |
| 0      | jacks   | u32  | 2     |
| 4      | streams | u32  | 2     |
| 8      | chmaps  | u32  | 2     |

Two jacks (headphone out, mic in). Two streams (one output, one input). Two
channel maps (one per stream).

### Control Queue (queue 0)

Guest sends control messages: first descriptor is a readable `virtio_snd_hdr`
(`u32 code`), last descriptor is a writable response. Handle all standard
request codes:

#### VIRTIO_SND_R_JACK_INFO (0x0001)

Request body: `virtio_snd_query_info { start_id: u32, count: u32, size: u32 }`.
Reply with array of `virtio_snd_jack_info` structs (36 bytes each): `hdr` (4
bytes), `features` (u32), `hda_reg_defconf` (u32), `hda_reg_caps` (u32),
`connected` (u8), padding (3 bytes).

- Jack 0: headphone output, connected=1
- Jack 1: microphone input, connected=1

#### VIRTIO_SND_R_PCM_INFO (0x0100)

Request body: `virtio_snd_query_info`. Reply with array of `virtio_snd_pcm_info`
structs (36 bytes each): `hdr` (4 bytes), `features` (u32), `formats` (u64
bitmask), `rates` (u64 bitmask), `direction` (u8), `channels_min` (u8),
`channels_max` (u8), padding (5 bytes).

- Stream 0: direction=OUTPUT (0), channels 1–2, formats = S16|S32|FLOAT32 (bits
  2, 4, 9), rates = 44100|48000|96000 (bits 5, 6, 8)
- Stream 1: direction=INPUT (1), channels 1–2, same formats and rates

#### VIRTIO_SND_R_CHMAP_INFO (0x0200)

Request body: `virtio_snd_query_info`. Reply with array of
`virtio_snd_chmap_info` structs: `hdr` (4 bytes), `direction` (u8), `channels`
(u8), `positions[18]` (u8 each).

- Chmap 0: OUTPUT, 2ch, FL (0x02) / FR (0x03)
- Chmap 1: INPUT, 2ch, FL / FR

#### VIRTIO_SND_R_PCM_SET_PARAMS (0x0200)

Request:
`virtio_snd_pcm_set_params { hdr, stream_id, buffer_bytes, period_bytes, features, channels, format, rate }`.
Store per-stream. Configure the AudioUnit's stream format to match — build an
`AudioStreamBasicDescription` from the negotiated parameters.

Format enum → Core Audio mapping:

- S16 (2): `kAudioFormatFlagIsSignedInteger`, mBitsPerChannel=16
- S32 (4): `kAudioFormatFlagIsSignedInteger`, mBitsPerChannel=32
- FLOAT32 (9): `kAudioFormatFlagIsFloat`, mBitsPerChannel=32

Rate enum → sample rate:

- 44100 (5): 44100.0
- 48000 (6): 48000.0
- 96000 (8): 96000.0

#### VIRTIO_SND_R_PCM_PREPARE (0x0300)

Create and initialize the AudioUnit for this stream if not already done:

Output stream (stream 0):

- `AudioComponentFindNext(nil, &desc)` with
  `componentType = kAudioUnitType_Output`,
  `componentSubType = kAudioUnitSubType_DefaultOutput`
- `AudioComponentInstanceNew(component, &audioUnit)`
- Set stream format via `kAudioUnitProperty_StreamFormat` on
  `kAudioUnitScope_Input`, element 0
- Set render callback via `kAudioUnitProperty_SetRenderCallback` — callback
  pulls from the lock-free ring buffer
- Set `kAudioDevicePropertyBufferFrameSize` to 256 frames (try 128 first; if the
  device rejects it, fall back to 256, then 512)
- `AudioUnitInitialize()`

Input stream (stream 1):

- Same component lookup but `componentSubType = kAudioUnitSubType_HALOutput`
- Enable input:
  `AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO, scope: Input, element: 1, value: 1)`
- Disable output: same property, `scope: Output, element: 0, value: 0`
- Set input callback via `kAudioOutputUnitProperty_SetInputCallback`
- In the callback: `AudioUnitRender()` into a buffer, push into capture ring
- `AudioUnitInitialize()`

#### VIRTIO_SND_R_PCM_START (0x0500)

`AudioOutputUnitStart(audioUnit)`.

#### VIRTIO_SND_R_PCM_STOP (0x0600)

`AudioOutputUnitStop(audioUnit)`.

#### VIRTIO_SND_R_PCM_RELEASE (0x0400)

`AudioComponentInstanceDispose(audioUnit)`, tear down, nil out.

#### VIRTIO_SND_R_JACK_REMAP (0x0002)

Accept and acknowledge (no-op for virtual jacks).

#### All others

Reply `VIRTIO_SND_S_NOT_SUPP` (0x8003).

#### Reply Status Codes

| Code   | Name                  |
| ------ | --------------------- |
| 0x8000 | VIRTIO_SND_S_OK       |
| 0x8001 | VIRTIO_SND_S_BAD_MSG  |
| 0x8002 | VIRTIO_SND_S_IO_ERR   |
| 0x8003 | VIRTIO_SND_S_NOT_SUPP |

### TX Queue (queue 2) — Audio Output

Descriptor chain layout:

1. First descriptor (readable, 12 bytes):
   `virtio_snd_pcm_xfer { stream_id: u32 }`
2. Middle descriptors (readable): raw PCM audio data (format per set_params,
   interleaved)
3. Last descriptor (writable, 8 bytes):
   `virtio_snd_pcm_status { status: u32, latency_bytes: u32 }`

On `handleNotify` for txq: pop available buffers, read PCM data from middle
descriptors, push into a lock-free ring buffer that the AudioUnit render
callback pulls from. Convert sample format if needed (guest S16LE → Float32 for
Core Audio happens in the render callback, or in the push path — whichever is
simpler). Write `status = VIRTIO_SND_S_OK` and `latency_bytes` = ring buffer
fill level in bytes. Push used ring, raise interrupt.

Ring buffer sizing: at least 4 × period_bytes to absorb scheduling jitter.

### RX Queue (queue 3) — Audio Input (Capture)

Same descriptor layout as TX but data descriptors are device-writable. The
AudioUnit input render callback pushes captured PCM into a capture ring buffer.
On `handleNotify` for rxq: pop available writable buffers, fill from the capture
ring (or write silence + status=OK if the ring is empty). Push used ring, raise
interrupt.

### Event Queue (queue 1)

For jack connect/disconnect notifications and period elapsed events. Use
`AudioObjectAddPropertyListener` on `kAudioHardwarePropertyDefaultOutputDevice`
and `kAudioHardwarePropertyDefaultInputDevice` to detect device changes. When a
change occurs, write a `virtio_snd_event { hdr: { code } }` to an available
event buffer:

| Code   | Event                             |
| ------ | --------------------------------- |
| 0x1000 | VIRTIO_SND_EVT_JACK_CONNECTED     |
| 0x1001 | VIRTIO_SND_EVT_JACK_DISCONNECTED  |
| 0x1100 | VIRTIO_SND_EVT_PCM_PERIOD_ELAPSED |

Same injection pattern as `VirtioInput` event delivery (pending queue +
`eventLock`).

### Threading

`handleNotify` is called from vCPU threads. AudioUnit is not thread-safe for
configuration but render callbacks are safe after initialization. All
setup/teardown (prepare, start, stop, release) must happen on a dedicated serial
`DispatchQueue`. TX buffer scheduling (pushing into the ring) can happen from
the vCPU thread. The render callback runs on Core Audio's real-time thread — it
must never allocate, lock a mutex, or block. The ring buffer must be lock-free
(use atomic head/tail indices).

### Build

`import AudioToolbox` and `import CoreAudio`. Add
`.linkedFramework("AudioToolbox")` and `.linkedFramework("CoreAudio")` to
`Package.swift`.

---

## 3. virtio-net (VirtioNet.swift) — Slot 6

Networking backed by vmnet.framework (macOS native VM networking).

- **Device ID:** 1 (virtio spec §5.1)
- **Features:** `VIRTIO_NET_F_MAC` (bit 5), `VIRTIO_NET_F_STATUS` (bit 16)
- **Queues:** 2 (receiveq=0, transmitq=1)
- **CLI flag:** `--net` (optional, off by default). When absent, don't register
  slot 6.

### Config Space (virtio_net_config, spec §5.1.4)

| Offset | Field  | Type   | Value                    |
| ------ | ------ | ------ | ------------------------ |
| 0–5    | mac    | u8 × 6 | Locally-administered MAC |
| 6      | status | u16    | 1 (VIRTIO_NET_S_LINK_UP) |

Generate a locally-administered MAC at init: `02:AC:05:xx:xx:xx` where `xx`
bytes are random (using `SecRandomCopyBytes`). The `02` prefix sets the
locally-administered bit. `configRead` returns these bytes packed into u32s.

### Entitlement

vmnet.framework requires `com.apple.vm.networking`. Add to
`hypervisor.entitlements`:

```xml
<key>com.apple.vm.networking</key>
<true/>
```

### vmnet.framework Setup

```swift
import vmnet
```

If `import vmnet` doesn't work in Swift (it's a C framework), use the module map
approach or call via the C interop (`vmnet/vmnet.h`). Check the vmnet API
availability — it's been in macOS since 10.15.

Initialization:

```swift
let iface_desc: [String: Any] = [
    vmnet_operation_mode_key: VMNET_SHARED_MODE,  // NAT
]
let queue = DispatchQueue(label: "vmnet", qos: .userInteractive)
let iface = vmnet_start_interface(iface_desc as CFDictionary, queue) { status, params in
    // status == VMNET_SUCCESS means ready
    // params contains vmnet_mac_address_key (assigned MAC),
    // vmnet_max_packet_size_key, vmnet_mtu_key
}
```

Register packet callback:

```swift
vmnet_interface_set_event_callback(iface, VMNET_INTERFACE_PACKETS_AVAILABLE, queue) {
    // Packets available — call vmnet_read
}
```

On teardown: `vmnet_stop_interface(iface, queue) { ... }`.

### TX (queue 1) — Guest Sends Packets

On `handleNotify` for transmitq: pop available descriptor chains. Layout:

1. First descriptor (readable, 12 bytes): virtio-net header
   (`flags: u8, gso_type: u8, hdr_len: u16, gso_size: u16, csum_start: u16, csum_offset: u16, num_buffers: u16`
   — 12 bytes total for virtio 1.0 without VIRTIO_NET_F_MRG_RXBUF)
2. Remaining descriptors (readable): Ethernet frame data

Strip the 12-byte virtio-net header. Concatenate the Ethernet frame bytes from
remaining descriptors. Pass to `vmnet_write(interface, &packets, &count)` where
packets is a `vmpktdesc` array. Push to used ring with `bytesWritten = 0`
(device-writable bytes = 0 for TX), raise interrupt.

### RX (queue 0) — Host Delivers Packets to Guest

When the vmnet event callback fires `VMNET_INTERFACE_PACKETS_AVAILABLE`:

1. `vmnet_read(interface, &packets, &count)` to get Ethernet frames
2. For each received packet: prepend a 12-byte virtio-net header (all zeros — no
   checksum offload, no GSO)
3. Pop a writable buffer from receiveq, write header + frame data
4. Push to used ring with `bytesWritten` = 12 + frame length, raise interrupt

If no guest buffers are available when packets arrive, queue them (up to 256
packets, drop oldest on overflow — same pattern as `VirtioInput.pendingEvents`).
When the guest posts new buffers (`handleNotify` on queue 0), drain pending.

### Threading

vmnet callbacks arrive on the dedicated dispatch queue. Use an `NSLock`
(matching `VirtioInput`'s `eventLock` pattern) to protect the pending packet
queue and `lastAvailIdx` for the RX queue. TX in `handleNotify` runs on the vCPU
thread — `vmnet_write` is safe to call from any thread.

### Graceful Degradation

If `vmnet_start_interface` fails (missing entitlement, SIP restriction, etc.):
print a warning to stderr and skip device registration. Don't crash. The guest
simply won't see a network device at probe time.

### Build

`import vmnet`. Add to `Package.swift` linker settings:

```swift
.linkedFramework("vmnet"),
```

If Swift can't find the vmnet module directly, add:

```swift
.unsafeFlags(["-Xcc", "-I/usr/include"])
```

or create a `module.modulemap` that wraps `<vmnet/vmnet.h>`.

---

## Changes to Existing Files

### main.swift

Add to `Config` struct:

```swift
let audio: Bool
let net: Bool
```

Add argument parsing for `--audio` and `--net` (boolean flags, no arguments).

Add to `printUsage()`:

```console
  --audio              Enable audio output/input (virtio-snd)
  --net                Enable networking (virtio-net, vmnet NAT)
```

Device registration block (after existing slot 4):

```swift
// Slot 5: virtio-snd (optional)
if config.audio {
    let sound = VirtioSoundBackend()
    vm.addVirtioDevice(slot: 5, backend: sound)
    print("  Audio: enabled (slot 5)")
} else {
    print("  Audio: disabled")
}

// Slot 6: virtio-net (optional)
if config.net {
    if let net = VirtioNetBackend.create(verbose: config.verbose) {
        vm.addVirtioDevice(slot: 6, backend: net)
        print("  Network: enabled (slot 6)")
    } else {
        print("  Network: failed to start vmnet (check entitlements)")
    }
} else {
    print("  Network: disabled")
}

// Slot 7: virtio-rng (always present)
let rng = VirtioRngBackend()
vm.addVirtioDevice(slot: 7, backend: rng)
```

Use a failable factory (`VirtioNetBackend.create()`) for the graceful
degradation path.

### Package.swift

Add to `linkerSettings`:

```swift
.linkedFramework("Security"),
.linkedFramework("AudioToolbox"),
.linkedFramework("CoreAudio"),
.linkedFramework("vmnet"),
```

### hypervisor.entitlements

Add:

```xml
<key>com.apple.vm.networking</key>
<true/>
```

### CLAUDE.md

Update the device backends table:

```md
| Backend              | File                | Virtio Device ID | Apple Framework  |
| -------------------- | ------------------- | ---------------- | ---------------- |
| `Virtio9PBackend`    | `Virtio9P.swift`    | 9                | Foundation (FS)  |
| `VirtioInputBackend` | `VirtioInput.swift` | 18               | AppKit (NSEvent) |
| `VirtioMetalBackend` | `VirtioMetal.swift` | 22 (custom)      | Metal            |
| `VirtioBlockBackend` | `VirtioBlock.swift` | 2                | Foundation (FS)  |
| `VirtioSoundBackend` | `VirtioSound.swift` | 25               | AudioToolbox     |
| `VirtioNetBackend`   | `VirtioNet.swift`   | 1                | vmnet            |
| `VirtioRngBackend`   | `VirtioRng.swift`   | 4                | Security         |
```

Update the slot list in `main.swift` file header and in CLAUDE.md.

---

## File Summary

**New files:**

- `Sources/VirtioRng.swift`
- `Sources/VirtioSound.swift`
- `Sources/VirtioNet.swift`

**Modified files:**

- `Sources/main.swift`
- `Package.swift`
- `hypervisor.entitlements`
- `CLAUDE.md`

---

## Verification

After each device:

1. **virtio-rng:** `swift build` compiles. Smoke test: the device is always
   registered, so boot the OS kernel — it won't probe device ID 4 yet but the
   MMIO transport should respond to magic/version/device_id reads without
   crashing.

2. **virtio-snd:** `swift build` compiles. Verify AudioUnit setup doesn't crash
   on import. No end-to-end test possible (guest driver doesn't exist yet), but
   print log lines on control queue operations for future debugging.

3. **virtio-net:** `swift build` compiles. `make sign` to apply the updated
   entitlements. Boot the OS kernel — verify no crash. vmnet may print a warning
   if entitlements aren't applied (graceful degradation should handle this).
   Test: `make sign && make run KERNEL=<path> ARGS="--net --verbose"` — look for
   "Network: enabled (slot 6)" or the graceful failure message.

After all three: `make sign && make install` to update
`~/.local/bin/hypervisor`.
