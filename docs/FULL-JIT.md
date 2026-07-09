# Full JIT on pre-APRR devices (A9/A10) — diagnosis & fix plan

Node runs today with **`--jitless`**. This documents exactly why full JIT SIGBUSes on the A9,
and the patch needed to enable it (which would also restore WebAssembly).

## Symptom

Default (JIT) mode crashes immediately (`exit 138`). Under `lldb`:

```
stop reason = EXC_BAD_ACCESS (code=2, address=0x106088960)   # code=2 = protection failure
frame #0: 0x106088960:  stp x29, x30, [sp, #-0x10]!          # a function prologue
```

V8 jumped to code it generated, but the page **isn't executable**. Not a codegen bug — a
memory-permission bug: the code page is read-write, never read-execute.

## Root cause

V8 has exactly two hardware mechanisms for safe W^X JIT (`src/base/build_config.h`):

- `V8_HAS_PTHREAD_JIT_WRITE_PROTECT` — Apple **APRR** (`pthread_jit_write_protect_np`). arm64 macOS / iOS-simulator only.
- `V8_HAS_PKU_JIT_WRITE_PROTECT` — Intel **PKU**. x86 Linux only.

On a **real iOS arm64 device** *both are 0*. The **A9/A10 have no APRR** (that's A11+), and there's no PKU on ARM.
When neither is available, V8's `RwxMemoryWriteScope` is a **no-op** and V8 assumes code memory can be
**permanently RWX**: `src/heap/code-range.cc:236` sets the whole code region to
`PageAllocator::kReadWriteExecute` once and never changes it.

iOS enforces **W^X** — it won't grant a page both write and execute — so the region comes back
read-write with **execute silently dropped**. Every JIT'd call then faults. V8-on-iOS was only ever
designed for **jitless** (that's how Chrome for iOS ships), so there is no `mprotect` fallback.

The device *is* capable of JIT: `probe/` proves the classic W^X sequence
(`mmap(RW)` → write → `mprotect(RX)` → execute) works with Dopamine's `dynamic-codesigning`.
V8 just doesn't use it.

## Fix plan (add an `mprotect` W^X mechanism)

1. `src/base/build_config.h`: define a third mechanism, e.g.
   `V8_HAS_MPROTECT_JIT_WRITE_PROTECT 1` for `V8_OS_IOS && V8_HOST_ARCH_ARM64 && !TARGET_OS_SIMULATOR`.
2. `src/common/code-memory-access.{h,cc}`: implement `RwxMemoryWriteScope` for that mechanism —
   on enter (nesting 0→1) `mprotect(code_range, RW)`, on exit (1→0) `mprotect(code_range, RX)`,
   using a registered global code-range base/size. (Coarse but correct; HTTP-parsing/JS perf is
   network-bound anyway.)
3. `src/heap/code-range.cc`: allocate/keep the region **`kReadExecute`** instead of `kReadWriteExecute`
   and register it with the scope machinery.

**Caveats:** `code-memory-access.h` is included across V8, so each build iteration recompiles most of
V8 (~1 hr). Correctness of the nesting + covering every code-write path (WASM code space too) needs care.

## Alternative: pure-JS WebAssembly polyfill

Since the only *hard* blocker for real apps is that Node's `undici`/`fetch` parses HTTP with a WASM
`llhttp`, a pure-JS `WebAssembly` polyfill loaded via `--require` (before undici) would let jitless Node
run HTTP without touching V8. Slower, possibly incomplete for complex modules, but a much cheaper route
to a working app. Tracked as an option.

PRs welcome on either path.
