<div align="center">

# node-ios

### Node.js 22 running on jailbroken iOS 15 (arm64)

*The first public Node.js build above v17 for iOS. Cross-compiled entirely in GitHub Actions — no Mac required.*

[![build](https://github.com/j0shua-SYSON/node-ios/actions/workflows/build.yml/badge.svg)](https://github.com/j0shua-SYSON/node-ios/actions/workflows/build.yml)
![platform](https://img.shields.io/badge/target-iOS%2015%2B%20·%20arm64%20·%20rootless-black)
![node](https://img.shields.io/badge/Node.js-22.19.0-339933?logo=node.js&logoColor=white)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

Nobody had published a Node.js build newer than **v17** for iOS — the jailbreak repos froze at 16–17
(2022), and [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) tops out at 18 as an
*embeddable framework*, not a CLI. This repo cross-compiles **mainline Node 22.19** to a standalone
`iphoneos-arm64` binary that runs on a **jailbroken iPhone** — proven on an **iPhone 6s Plus (Apple A9),
iOS 15.8.5, Dopamine**.

## It actually runs (real output from the device)

```
$ ./node --jitless smoke.mjs
NODE_VERSION v22.19.0
ARCH arm64 PLATFORM ios
SQLITE_OK 42          # node:sqlite works
LOOP_OK 14999995      # JS execution works
TLS_ROOTS present     # bundled CA roots → HTTPS works
SMOKE_DONE
```

## What works / what doesn't

| | |
|---|---|
| ✅ Runs `node --version`, executes JavaScript | in **`--jitless`** mode |
| ✅ **`node:sqlite`** (built-in) | works |
| ✅ TLS / crypto (bundled Mozilla CA roots) | works |
| ✅ `fork()` / `child_process` | works (Dopamine `forkfix`) |
| ⚠️ **Full JIT** (TurboFan) | **SIGBUS on A9** — see below |
| ⚠️ **WebAssembly** | disabled (jitless on Node 22 / V8 12.4, no DrumBrake) |

### Why jitless (and the path to full JIT)

The A9 has **no APRR**, so V8's Apple JIT path (`MAP_JIT` + `pthread_jit_write_protect_np`) is a dead
end — `MAP_JIT` returns `EINVAL`, and executing from a normal RWX page `SIGBUS`es. A stock JIT build
boots and prints `--version`, but the instant V8 runs JITed code it dies (exit 138). `--jitless` sidesteps
all of it: Ignition-only, ~40% slower on pure compute (fine for I/O-bound work), no executable memory.

**Full JIT is achievable, just not finished.** The [`probe/`](probe) tool confirmed on-device that the
classic **W^X** sequence *does* work here (map RW → write → `mprotect` R+X → execute), and the binary is
`ldid`-signed with `dynamic-codesigning` and trust-cached by Dopamine at spawn. So V8 needs to be patched
to use plain `mprotect` instead of the `MAP_JIT` path — then full JIT + WASM should return. PRs welcome.

## The patch set

The entire iOS delta is [`scripts/ios-source-fixups.sh`](scripts/ios-source-fixups.sh) — four small,
commented fixes applied to Node's source before `configure`:

| Blocker | Fix |
|---|---|
| gyp emits GNU `ld --start-group/--end-group` for non-mac targets | strip them (Apple's `ld64` resolves archives globally) |
| c-ares includes `<sys/random.h>` (absent in iOS SDK) | undef `HAVE_SYS_RANDOM_H` → `arc4random_buf` |
| `crypto_context.cc` uses macOS-only `SecTrustSettings*` under `#ifdef __APPLE__` | guard with `TARGET_OS_OSX` |
| Abseil (via V8) needs `-framework CoreFoundation`, only linked for the `mac` flavor | link Darwin frameworks for iOS via `common.gypi` |

Plus: pin **Python 3.12** (Node's `configure` rejects 3.14) and use **`-std=gnu++20`** for host *and*
target. That's it — it then compiles, links, and signs.

## Build it yourself

Everything runs in GitHub Actions on a macOS runner — **you don't need a Mac.**

1. Fork this repo.
2. Actions → **build** → *Run workflow* (pick a `node_ref`, default `v22.19.0`).
   The first run is slow (~80 min: a full V8 compile); it warms a ccache so re-runs are ~5 min.
3. Grab `node-<ver>-iphoneos-arm64` from the resulting Release.

## Run it on your device

```bash
scp node-v22.19.0-iphoneos-arm64 entitlements.plist mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip>
  mv node-v22.19.0-iphoneos-arm64 node && chmod +x node
  ldid -Sentitlements.plist node        # dynamic-codesigning; Dopamine trust-caches at spawn
  ./node --jitless --version            # -> v22.19.0
```

`--jitless` is required (see above). `node:sqlite` needs no flag; it's built in.

## Runtime model (validated first, in [`probe/`](probe))

Before investing in the Node build, [`probe/probe.c`](probe/probe.c) validated on-device that an
`ldid`-signed arm64 binary with `dynamic-codesigning` runs under Dopamine (auto-trust-cached, no manual
trustcache), `fork()` works, and JIT is possible via `mprotect` W^X (but not `MAP_JIT`). Findings:
[`probe/FINDINGS.md`](probe/FINDINGS.md).

## Credits

- [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) — prior art for Node-on-mobile.
- [Dopamine](https://github.com/opa334/Dopamine) + [Procursus](https://github.com/ProcursusTeam/Procursus) — the rootless jailbreak + bootstrap.

## License

MIT — see [LICENSE](LICENSE). Node.js itself is MIT-licensed by its authors.

<div align="center"><sub>Experimental. Tested on one device (iPhone 6s Plus / iOS 15.8.5 / Dopamine). Try it elsewhere and open an issue.</sub></div>
