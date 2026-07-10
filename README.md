<div align="center">

# node-ios

### Node.js 22 running on jailbroken iOS 15 (arm64)

*A standalone mainline Node.js 22 CLI for jailbroken iOS, cross-compiled entirely in GitHub Actions. No Mac required.*

[![build](https://github.com/j0shua-SYSON/node-ios/actions/workflows/build.yml/badge.svg)](https://github.com/j0shua-SYSON/node-ios/actions/workflows/build.yml)
![platform](https://img.shields.io/badge/target-iOS%2015%2B%20·%20arm64%20·%20rootless-black)
![node](https://img.shields.io/badge/Node.js-22.19.0-339933?logo=node.js&logoColor=white)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

This repo cross-compiles **mainline Node 22.19** to a standalone `iphoneos-arm64` binary that runs on a
**jailbroken iPhone**, proven on an **iPhone 6s Plus (Apple A9), iOS 15.8.5, Dopamine**. Everything is
built in GitHub Actions from a small, commented patch set. No Mac required.

## It actually runs (real output from the device)

```
$ ./node --jitless smoke.mjs
NODE_VERSION v22.19.0
ARCH arm64 PLATFORM ios
SQLITE_OK 42          # node:sqlite works
LOOP_OK 14999995      # JS execution works
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
| 🚧 **Full JIT + WebAssembly** | solved on the A9 (see below); being folded into this standalone build |

This repo's published binary currently runs in **`--jitless`** mode (V8 interpreter only, no executable
memory). That's a safe default, and it's plenty for I/O-bound work, but it also disables WebAssembly on
Node 22 / V8 12.4.

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

That patch set currently lives in the sibling
[openclaw-ios](https://github.com/j0shua-SYSON/openclaw-ios) build; folding it into this standalone
`node-ios` build is the next step here. Until then, this repo's release runs `--jitless`.

## The patch set (the jitless build)

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

1. Fork this repo.
2. Actions → **build** → *Run workflow* (pick a `node_ref`, default `v22.19.0`).
   The first run is slow (~80 min: a full V8 compile); it warms a ccache so re-runs are faster.
3. Grab `node-<ver>-iphoneos-arm64` from the resulting Release.

## Run it on your device

```bash
scp node-v22.19.0-iphoneos-arm64 entitlements.plist mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip>
  mv node-v22.19.0-iphoneos-arm64 node && chmod +x node
  ldid -Sentitlements.plist node        # dynamic-codesigning; Dopamine trust-caches at spawn
  ./node --jitless --version            # -> v22.19.0
```

This repo's binary runs with `--jitless` (see above). `node:sqlite` needs no flag; it's built in.

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
