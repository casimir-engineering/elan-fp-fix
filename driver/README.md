# Patched elanpress driver sources

`elanpress.c` / `elanpress.h` are this repo's patched version of the
[`elanpress` driver](https://github.com/filip-rs/libfprint/tree/elanpress)
(upstream commit `34fc394`, LGPL-2.1+, © Filip Spanne; modifications © the
elan-fp-fix contributors under the same license).

`install-driver.sh` fetches the pinned upstream commit and copies these two
files over `libfprint/drivers/` before building, so the rest of libfprint is
byte-identical to the reviewed upstream tree.

## Why the patch?

The stock elanpress driver was written against firmware that answers the
blocking `pre_scan` (`0x40 0x3f`) handshake with `0x55` when a finger lands.
Firmware **8.00** (ASUS Zenbook S 13 UM5302TA and likely others) never answers
`pre_scan`, so stock enrollment times out. Changes, established by direct USB
probing of fw 8.00:

- **Finger detection from frame content** instead of `pre_scan`: a resting
  finger raises the frame mean well above the background (~3020 idle,
  5000–6800 pressed). Hysteresis: on at background +250, off below +120.
- **`led_on` (`0x40 0x31`) removed**: on fw 8.00 it freezes live imaging until
  the device is re-enumerated.
- **A `read_sensor_status` (`0x40 0x13`) read before every `get_image`**: the
  status read arms a fresh exposure; without it frames are stale and never
  react to the finger. 150 ms between polls gives the exposure time to
  integrate.
- **Lift debounce**: fw 8.00 interleaves a background-level frame between good
  exposures while the finger rests, so a touch only ends after 2 consecutive
  low frames.
