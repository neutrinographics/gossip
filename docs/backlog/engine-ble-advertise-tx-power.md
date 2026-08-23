# Make Bluetooth advertising transmit power configurable

**Track:** Sync engine   **Depends on:** nothing

## What this is

The BLE transport lets an app choose scan and advertising duty-cycle modes
(low power / balanced / low latency), but the underlying bluey library
hardcodes the advertising *transmit power* to HIGH on Android. Apps that
choose a low-power advertising mode still radiate at full strength. This
adds a TX-power option through the same layers the mode enums already
travel (bluey upstream first, then an owned value object in the transport).

## Why it matters

Advertising is the always-on background activity of a discoverable device;
transmit power is one of its two battery levers, and today it is pinned to
the most expensive setting.

## Rough approach

Bluey is our library: add the AdvertiseSettings TX-power parameter upstream
(mirroring how ScanMode was added), regenerate the platform bridge, then
plumb an owned enum through the transport exactly like AdvertiseMode.

## Related

- Follow-up noted during recommendation R2 of
  [audits/2026-08-20-wire-scheduling-audit.md](../audits/2026-08-20-wire-scheduling-audit.md)
  (bluey Advertiser hardcodes HIGH).
- Precedent: the owned ScanMode/AdvertiseMode enums shipped with the
  duty-cycle work.
