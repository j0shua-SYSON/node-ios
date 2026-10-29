<div align="center">

# node-ios

### Node.js 22 running on jailbroken iOS 15 (arm64)

*A standalone mainline Node.js 22 CLI for jailbroken iOS, cross-compiled entirely in GitHub Actions. No Mac required.*

[![build](https://github.com/repos1tory/node-ios/actions/workflows/build.yml/badge.svg)](https://github.com/repos1tory/node-ios/actions/workflows/build.yml)
![platform](https://img.shields.io/badge/target-iOS%2015%2B%20·%20arm64%20·%20rootless-black)
![node](https://img.shields.io/badge/Node.js-22.19.0-339933?logo=node.js&logoColor=white)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

This repo cross-compiles **mainline Node 22.19** to a standalone `iphoneos-arm64` binary for
**rootless Dopamine and palera1n iPhones and iPads**. The build is produced in GitHub Actions from a
small, commented patch set. No Mac is required.

## It actually runs (real output from the device)

```
$ ./node --predictable --single-threaded --disable-wasm-trap-handler smoke.mjs
NODE_VERSION v22.19.0
ARCH arm64 PLATFORM ios
EXEC_FLAGS --predictable --single-threaded --disable-wasm-trap-handler
RUNTIME_OK
SQLITE_OK 42          # node:sqlite works
WASM_OK 3             # WebAssembly compiles, instantiates, executes
LOOP_OK 14999995      # JIT-compiled JS runs
TLS_ROOTS present     # bundled CA roots -> HTTPS works
SMOKE_DONE
```

## What works

| | |
|---|---|
| ✅ Runs `node --version`, executes JavaScript | works |
| ✅ **`node:sqlite`** (built-in) | works |
| ✅ TLS / crypto (bundled Mozilla CA roots) | works |
| ✅ `fork()` / `child_process` | works (Dopamine `forkfix`) |
| ✅ **Full JIT (TurboFan) + WebAssembly** | works on the A9 via the mprotect W^X patch (see below) |
| ✅ **WebAssembly *memory*** (blake3, esbuild-wasm, ...) | works with `--disable-wasm-trap-handler` (required — see Gotchas) |
| ⚠️ `wrangler` 4.x | works in practice — see the companion [wrangler-ios](https://github.com/repos1tory/wrangler-ios) |

The published binary ships **full JIT** — run it with the three flags below.

## Full JIT on the A9 (solved)

For a long time the open question was whether V8's JIT could run at all on a pre-A11 chip like the A9.
It has **no APRR**, so V8's Apple JIT path (`MAP_JIT` + `pthread_jit_write_protect_np`) is a dead end:
`MAP_JIT` returns `EINVAL`, `pthread_jit_write_protect_np` is a no-op, and iOS silently downgrades an
RWX request to RW even for a `dynamic-codesigning`-entitled binary. Interpreter-only (`--jitless`) is
the usual way around this.

That question now has an answer: **full JIT (JavaScript TurboFan *and* WebAssembly) runs on the A9.**
The fix is a patch to V8 that uses the classic **W^X** sequence (map RW, write, `mprotect` RX, execute)
over each of V8's registered code ranges, including the separate WebAssembly code space. On-device:

```
$ ./node --predictable --single-threaded jit-test.mjs
JIT_HOTLOOP_OK -767246336   # TurboFan-compiled hot loop executed
ANSWER 42
WASM_OK 42                  # WebAssembly compiled, instantiated, executed
JIT_TEST_DONE
```

The patch is now part of this repo's build: see
[`scripts/ios-source-fixups.sh`](scripts/ios-source-fixups.sh) (`V8: full JIT on pre-APRR iOS via
mprotect W^X`). The released binary contains it — `jit-test.mjs` passes on-device.

## Runtime flags you need (read this first)

This build is patched V8; run it with **all three** of these flags:

```sh
node --predictable --single-threaded --disable-wasm-trap-handler your-script.js
```

| Flag | Why |
|---|---|
| `--predictable` + `--single-threaded` | The W^X patch flips code-page permissions **process-wide** via `mprotect`. V8's background compiler threads would race with that flip. These flags remove the race (at the cost of some compile speed). Required for JIT to be crash-safe. |
| `--disable-wasm-trap-handler` | **Required for anything using WebAssembly memory** (blake3-wasm, esbuild-wasm, sql.js, ...). With the trap handler enabled, V8 reserves **10GB of guarded address space per wasm memory**; iOS caps process VA, so every wasm memory allocation fails with `could not allocate memory`. This flag drops the guard reservation. |

The repo's `entitlements.plist` also requests
`com.apple.developer.kernel.extended-virtual-addressing`, which lifts iOS's default per-process VA
cap (needed for 2GB+ reservations, e.g. huge ArrayBuffers).

The iOS V8 snapshot must not inherit optional ARM instructions from the Apple Silicon build host.
The build masks those host-only feature bits for the iOS target and includes a device smoke check for
the affected atomic operations. The matching Debian package is versioned independently from Node;
packages that run Node on-device should depend on the current `nodejs` package in the
[repos1tory Sileo repo](https://repos1tory.github.io/) instead of bundling their own runtime.

### Two more iOS quirks you'll hit with real tools

- **There is no `/bin/sh`** on rootless jailbreaks (the rootfs is read-only; the shell lives at
  `/var/jb/bin/sh`). `spawn()`/`execFile()` without a shell work fine, but `execSync("...")` defaults
  to `/bin/sh` and fails with `ENOENT` — pass `{ shell: "/var/jb/bin/sh" }`, or make sure any tool
  you use spawns binaries directly. Node itself is unaffected otherwise.
- **Spawned child `node` processes need these flags too.** If a tool re-spawns `node` from `PATH`,
  make sure the `node` on `PATH` is the wrapper/shim this installer writes (which adds the flags),
  not the raw binary.

## Companion: wrangler on iOS

Wrangler 4.x runs on-device using this node build — see
**[repos1tory/wrangler-ios](https://github.com/repos1tory/wrangler-ios)** for a one-command installer.

## The patch set

The iOS delta is [`scripts/ios-source-fixups.sh`](scripts/ios-source-fixups.sh) — small, commented
fixes applied to Node's source before `configure`:

| Blocker | Fix |
|---|---|
| gyp emits GNU `ld --start-group/--end-group` for non-mac targets | strip them (Apple's `ld64` resolves archives globally) |
| c-ares includes `<sys/random.h>` (absent in iOS SDK) | undef `HAVE_SYS_RANDOM_H` -> `arc4random_buf` |
| `crypto_context.cc` uses macOS-only `SecTrustSettings*` under `#ifdef __APPLE__` | guard with `TARGET_OS_OSX` |
| Abseil (via V8) needs `-framework CoreFoundation`, only linked for the `mac` flavor | link Darwin frameworks for iOS via `common.gypi` |

Plus: pin **Python 3.12** (Node's `configure` rejects 3.14) and use **`-std=gnu++20`** for host *and*
target. That's it; it then compiles, links, and signs. (The full-JIT build adds a further V8 W^X patch,
described above.)

## Build it yourself

Everything runs in GitHub Actions on a macOS runner. **You don't need a Mac.**

1. Actions → **build** → *Run workflow* (pick a `node_ref`, default `v22.19.0`, and a Debian
   `package_revision`). The first run is slow (~80 min: a full V8 compile); it warms a ccache so
   re-runs are faster.
2. Download the workflow artifact and run `smoke.mjs` plus `jit-test.mjs` on a physical device.
3. After device verification, publish the binary and `.deb` under a new release tag, then run the
   repos1tory `publish package` workflow to refresh the Sileo index.

## Run it on your device

**One-line install (on the device, Dopamine or palera1n rootless):**

```sh
curl -fsSL https://raw.githubusercontent.com/repos1tory/node-ios/main/scripts/install-on-device.sh | sh
```

That downloads the verified release binary, signs it with `entitlements.plist` (ldid), installs it to
`/var/jb/usr/lib/node-ios/`, and writes a `/var/jb/usr/bin/node` shim that always passes the three
required flags. Then just:

```sh
node --version            # -> v22.19.0
node smoke.mjs            # full smoke test (JIT + wasm + sqlite + TLS)
```

**Manual install:**

```bash
scp node-v22.19.0-iphoneos-arm64 entitlements.plist mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip>
  mv node-v22.19.0-iphoneos-arm64 node && chmod +x node
  ldid -Sentitlements.plist node                 # dynamic-codesigning + extended VA; Dopamine trust-caches at spawn
  ./node --predictable --single-threaded --disable-wasm-trap-handler --version
```

`node:sqlite` needs no flag; it's built in. `--jitless` remains available as a fallback for
environments where the JIT patch doesn't apply.

## Runtime model (validated first, in [`probe/`](probe))

Before investing in the Node build, [`probe/probe.c`](probe/probe.c) validated on-device that an
`ldid`-signed arm64 binary with `dynamic-codesigning` runs under Dopamine (auto-trust-cached, no manual
trustcache), `fork()` works, and JIT is possible via `mprotect` W^X (but not `MAP_JIT`). Findings:
[`probe/FINDINGS.md`](probe/FINDINGS.md).

## Credits

- [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) — prior art for Node on mobile.
- [Dopamine](https://github.com/opa334/Dopamine) + [Procursus](https://github.com/ProcursusTeam/Procursus) — the rootless jailbreak + bootstrap.

## License

MIT — see [LICENSE](LICENSE). Node.js itself is MIT-licensed by its authors.

<div align="center"><sub>Experimental. Tested on one device (iPhone 6s Plus / iOS 15.8.5 / Dopamine). Try it elsewhere and open an issue.</sub></div>
