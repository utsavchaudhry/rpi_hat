# RPi Hat Project — Progress Notes

Last updated: 2026-08-03

## Goal

Raspberry Pi 5 as a WiFi 7 bridge + audio relay for an NVIDIA Jetson Thor.
Pi has a mic + speaker attached (single USB-connected driver board). Thor
will run ROS 2 and eventually be the only device the user interacts with
directly. The Pi is a fast-iteration testbed; long-term plan is to replace
it with a custom in-house router board that does this one job (NAT +
audio relay) in dedicated hardware.

## Hardware

- Raspberry Pi 5
- Intel BE200 (WiFi 7 + BT 5.4, M.2 2230 Key E) on a PCIe-to-M.2 Key-E HAT
  - Onboard Pi WiFi = `wlan0` (currently connected to the home/office
    SSID, this is the upstream/internet connection)
  - BE200 = `wlan1` (added for WiFi 7; not yet in active use for anything)
  - Bluetooth on the BE200 requires a USB line from the HAT to a Pi USB
    port — WiFi rides PCIe, BT rides USB on Key-E cards.
- USB audio driver board with both mic and speaker wired through the same
  USB connection to the Pi (expected to enumerate as one ALSA card with
  both capture + playback subdevices).
- Target/downstream device: NVIDIA Jetson Thor, connected to the Pi via
  Eth(`eth0`), will run ROS 2.

## Networking (done)

- Pi's network stack is netplan-managed with `renderer: NetworkManager`
  (this is Ubuntu, not stock Raspberry Pi OS — connections show up as
  `netplan-eth0` etc. in `nmcli`).
- `eth0` is configured for NAT/DHCP sharing to the Thor via netplan's
  NetworkManager passthrough:
  ```yaml
  network:
    version: 2
    renderer: NetworkManager
    ethernets:
      eth0:
        networkmanager:
          passthrough:
            ipv4.method: shared
  ```
  This was used instead of a raw `nmcli connection modify` because
  netplan regenerates the NM keyfile from YAML and would silently wipe a
  manual nmcli change on next `netplan apply`/reboot.
- Result: Pi is `10.42.0.1` on `eth0`, hands out DHCP leases in
  `10.42.0.0/24` to whatever's plugged into `eth0` (currently just Thor
  once connected).

## Audio streaming plan

Two independent GStreamer RTP/UDP streams over the Pi↔Thor Ethernet link.
No ROS and no audio server (PulseAudio/PipeWire) needed on the Pi at all
— chosen over WebRTC (too much signaling/ICE overhead for a direct wired
hop) and raw netcat/socat piping (no jitter handling, fine only as a
throwaway smoke test).

- **Mic path:** Pi captures via `alsasrc` → `rtpL16pay` → `udpsink` to
  Thor `:5000`.
- **Speaker path:** Thor → `udpsink` to Pi `:5001` → `udpsrc` on Pi →
  `rtpL16depay` → `alsasink`.
- Codec: raw PCM (`L16`), 48kHz mono — no encode/decode latency, and
  bandwidth (~768kbps/direction) is trivial on wired gigabit. Revisit
  Opus only if this ever has to survive over the eventual wireless
  custom router.
- `rtpjitterbuffer latency=40` (much lower than GStreamer's 200ms
  default) since jitter on a direct wired LAN hop is minimal and this
  feeds a real-time control loop.
- Test commands (both directions) are in the conversation history where
  this was designed — re-derive by asking Claude for "the gst-launch
  test pipelines for mic/speaker over RTP" if this file is stale, or see
  below once codified into scripts.

### Phase 2 (ROS bridge, deferred until phase 1 audio works)

Pi side pipelines stay exactly as-is. On Thor, replace the temporary
`gst-launch` test sink/source with a small ROS 2 node that uses
GStreamer `appsink`/`appsrc` internally:
- `appsink` pulls buffers off the mic-receive pipeline → publish on a ROS
  topic (raw byte-array msg, or `audio_common_msgs/AudioData`).
- `appsrc` fed by a subscriber callback on the speaker topic → pushed
  into the speaker-send pipeline back to the Pi.

ROS is Thor-only; the Pi will never have ROS installed.

## Current blocker

USB audio board is **not detected at all** on the Pi:
- `arecord -l` → empty, no capture devices.
- `aplay -l` → only the two Pi HDMI outputs (`vc4-hdmi-0`, `vc4-hdmi-1`),
  no USB audio card registered.

This means the board isn't enumerating on the USB bus (or isn't binding
to a driver), not just "no capture support" — need to check at the USB
level, not just ALSA.

## Next steps

1. On the Pi, run and inspect:
   ```bash
   lsusb                  # does the board even show up on the bus?
   dmesg | tail -50       # USB enumeration / snd-usb-audio errors
   cat /proc/asound/cards # what ALSA actually registered
   lsmod | grep snd       # is snd-usb-audio loaded?
   ```
2. Likely causes to check in order:
   - Not in `lsusb` at all → power issue (board + speaker may exceed
     what the Pi USB port supplies; try a powered hub) or bad
     cable/port — also try a different Pi USB port (2 vs 3).
   - In `lsusb` but not in `/proc/asound/cards` → driver isn't binding,
     check `dmesg` timestamps around enumeration.
   - Registers but playback-only, no capture → mic might be on a
     separate USB interface on the same board; `lsusb -v` (sudo) to
     inspect audio interface descriptors.
3. Once the board is detected, get exact `hw:X,Y` device strings from
   `arecord -l`/`aplay -l` and fill them into the GStreamer pipelines
   above.
4. Validate mic → Thor and Thor → Pi speaker independently with
   `gst-launch-1.0` before writing any code.
5. Build the Thor-side ROS 2 bridge node (phase 2, per above).
6. Longer-term: design the custom in-house router hardware that
   replaces the Pi for this exact NAT + audio-relay job.
