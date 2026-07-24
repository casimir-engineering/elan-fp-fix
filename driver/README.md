# Patched elanpress driver sources

`elanpress.c` / `elanpress.h` are this repo's patched version of the
[`elanpress` driver](https://github.com/filip-rs/libfprint/tree/elanpress)
(upstream commit `34fc394`, LGPL-2.1+, © Filip Spanne; modifications © the
elan-fp-fix contributors under the same license).

`build-driver.sh` fetches the pinned upstream commit and copies these two
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
  react to the finger. Polls run 60 ms apart (~85 ms real cycle), verified at
  full finger contrast on fw 8.00.
- **Lift debounce**: fw 8.00 interleaves background-level frames between good
  exposures while the finger rests (the exposure needs ~100 ms to recharge, so
  they can come in pairs at this poll rate); a touch only ends after 4
  consecutive low frames.
- **Background self-healing**: if the finger already rests on the sensor when
  capture starts, the background reference is captured contaminated and would
  mask every touch; it is re-taken when the polled mean falls well below it.
- **Prompt cancellation**: between polls the capture machine sits in a delayed
  transition with no USB transfer in flight, so the driver fails the machine
  from its cancel hook; otherwise a cancelled verify (PAM timeout, GDM cancel)
  never completed and fprintd kept the device claimed until restart.
- **Low-latency verify**: verify/identify complete after 4 captured frames
  without waiting for the finger to lift; enrollment keeps collecting up to 10
  frames per touch for image diversity.
