# AGENTS.md

Pure Zig 0.16 package: shared RDAC LAN protocol policy used by `rdac-pw` and
`rdac-vad`.

## After changes

Run all four before finishing:

- `zig build test`
- `zig build`
- `zig fmt --check src build.zig`
- `zlint .`

Expected lint result is 0 errors and 0 warnings.

## Architecture notes

- `src/root.zig` re-exports every module and pulls their tests into the test
  artifact.
- Keep the package free of Avahi, DNS-SD, PipeWire, CoreAudio, and SCTP
  dependencies. `link_libc` exists only for `getifaddrs` in `local_ips.zig`.
- Do not add an allocator, logging, or a global Io instance. Functions return
  values or errors and callers log.
- `PcmFormat.s24_32` maps to 24 wire bits. Use `wireBits`, never
  `@intFromEnum`, at the sctp-wps boundary.
- TXT keys are matched case-insensitively. Rate entries outside
  `1..MAX_SAMPLE_RATE` are dropped, duplicates removed, and the list
  capped at `MAX_RATES`.
