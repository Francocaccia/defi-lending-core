# Reference model (C++)

An **independent re-implementation of the protocol's pure math**, written from
[`docs/DESIGN.md`](../docs/DESIGN.md) section 9 only (the author of this code never read the
Solidity). Foundry feeds the same inputs to the Solidity libraries and to this program and demands
identical outputs and identical failure behaviour. See
[`docs/DIFFERENTIAL_REPORT.md`](../docs/DIFFERENTIAL_REPORT.md) for the result.

## Build and test

Needs only CMake >= 3.16 and a C++17 compiler (GCC, Clang or MSVC). **No third-party
libraries**: the exact 256-bit arithmetic with a 512-bit `mulDiv` intermediate is hand-written
(`src/uint256.*`, ~250 lines) because MSVC has no `__int128` and a big-integer dependency would
have cost a download for very little code.

```bash
cmake -S reference-model -B reference-model/build -DCMAKE_BUILD_TYPE=Release
cmake --build reference-model/build
ctest --test-dir reference-model/build --output-on-failure
```

On Windows use a single-config generator (e.g. Ninja from a Visual Studio developer prompt) so the
binary lands in `reference-model/build/refmodel.exe`, where Foundry looks for it.

## Use

```text
refmodel <function> <arg1> <arg2> ...        # decimal or 0x-hex unsigned integers, < 2^256
```

| Result | stdout | stderr | exit |
|---|---|---|---|
| success | `0x` + one 32-byte big-endian word (64 lowercase hex digits) per returned value, one line | empty | 0 |
| the Solidity call would revert | empty | `error: <reason>` | 1 |
| bad usage (unknown function, wrong arity, unparsable / out-of-range argument, decimals > 255) | empty | `usage: <reason>` | 2 |

```bash
$ refmodel utilization 3 1
0x00000000000000000000000000000000000000000000000004a03ce68d215555     # 333333333333333333
```

Arguments: decimal or `0x`/`0X` hex, any hex case, leading zeros allowed; decimals arguments
(`*Decimals`, `dd`, `cd`) must be `<= 255` (they are `uint8` in the Solidity).

The 25 functions and their argument order are listed in
[`docs/M8_HANDOFF.md`](../docs/M8_HANDOFF.md) section 3; their semantics are
[`docs/DESIGN.md`](../docs/DESIGN.md) section 9.

## Layout

| Path | Content |
|---|---|
| `src/uint256.*` | `U256`: checked `+ - * /` (throw on overflow, R1), `mulDiv` / `mulDivUp` with a 512-bit intermediate (R2), `pow10` (R3), parsing and hex output |
| `src/model.*` | one function per row of DESIGN section 9, written as a transcription of the formulas |
| `src/cli.*`, `src/main.cpp` | argument parsing, dispatch table, output format and exit codes |
| `tests/` | dependency-free test harness; unit tests, CLI tests, and `test_vectors.cpp` (every line of `test/differential/vectors.txt`, run with decimal and with hex arguments) |
| `tests/cli_case.cmake` | black-box tests of the real binary (exit code, exact stdout, stderr prefix) |

## Design notes

- **Failure = exception.** Every checked operation throws `ModelError`; the CLI maps it to exit 1.
  Because C++ evaluates operands eagerly and `if`/`?:` lazily, rules R1-R5 of DESIGN 9.1 hold by
  construction, including "operands are evaluated even if the result would not depend on them".
- **Division** is plain shift-and-subtract over 512 bits: the simplest algorithm that is obviously
  correct. Speed is irrelevant (one call per process).
- **No floating point**, no `__int128`, no undefined behaviour on the arithmetic path.
- `UINT_MAX` of the spec is called `UINT256_MAX` in code (`<limits.h>` defines a macro `UINT_MAX`).
