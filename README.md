# HISAT2 — patched, cross-platform build (work in progress)

A minimal patched copy of [**HISAT2**](https://github.com/DaehwanKimLab/hisat2)
(2.2.3 / git-master base) that builds and runs natively on **Linux, macOS
(Intel + Apple Silicon), and Windows (x64 + ARM64)**, and reads
**gzip-compressed FASTQ directly** — no Perl wrapper, no `gzip.exe`, no temp
files.

For HISAT2's documentation, options, and canonical source, see the upstream
repository: <https://github.com/DaehwanKimLab/hisat2>. **This README covers only
how to build this tree and what was changed** — everything else is unchanged
from upstream.

> The **git-master** base matters: the `hisat2-2.2.x` release *tarball* has an
> old Makefile with no ARM support (it emits `-msse2` unconditionally and fails
> on ARM64). Master carries the arch-gated SIMD path (`third_party/sse2neon.h`)
> this tree relies on.

---

## Building from source

HISAT2 links only `-lpthread` and (now) `-lz`; there is no separate library to
build first. Run every command **from this directory** (the one containing
`Makefile`). On Windows the build is **native MinGW** — *not* MSVC, and *not*
the Cygwin-style "MSYS2 MSYS" shell.

### Toolchain / shell per platform

| Platform | Shell / prompt | CC / CXX | SIMD | C++ runtime | `ARCH` |
|---|---|---|---|---|---|
| Linux x64 | your terminal | `gcc` / `g++` | SSE2 | libstdc++ | *(auto)* |
| Linux ARM64 | your terminal | `gcc` / `g++` | NEON | libstdc++ | *(auto)* |
| macOS Intel | Terminal | `clang` / `clang++` | SSE2 | libc++ | *(auto)* |
| macOS Apple Silicon | Terminal | `clang` / `clang++` | NEON | libc++ | *(auto)* |
| Windows x64 | **MSYS2 UCRT64** | `gcc` / `g++` | SSE2 | libstdc++ | *(auto)* |
| Windows ARM64 | **MSYS2 CLANGARM64** | `clang` / `clang++` | NEON | libc++ | **`aarch64`** |

The Makefile picks the SIMD path from `ARCH ?= $(shell uname -m)`. On every
platform except **Windows ARM64** that is correct automatically. See that
section for why it must be forced there.

### Linux — x86-64 / ARM64

```bash
sudo apt install build-essential make zlib1g-dev     # Debian/Ubuntu
make
```

The `ARCH` detection selects SSE2 on x86-64 and NEON on aarch64 with no extra
flags. This builds the `-s`/`-l` (small/large-index) align, build, and inspect
binaries plus `hisat2-repeat`.

### macOS — Intel / Apple Silicon

zlib ships with the system SDK; Apple clang is fine.

```bash
make
```

Apple Silicon is detected as `arm64` and takes the NEON path automatically.

### Windows — x64  (MSYS2 **UCRT64** shell)

Install MSYS2 (<https://www.msys2.org>) and open the **"MSYS2 UCRT64"** shell
(*not* "MSYS2 MSYS"). The build tool is `mingw32-make`.

```bash
pacman -S --needed \
  mingw-w64-ucrt-x86_64-gcc  mingw-w64-ucrt-x86_64-make \
  mingw-w64-ucrt-x86_64-zlib mingw-w64-ucrt-x86_64-git

mingw32-make EXTRA_FLAGS="-static -static-libgcc -static-libstdc++"

strip hisat2-align-s.exe hisat2-align-l.exe hisat2-build-s.exe hisat2-build-l.exe \
      hisat2-inspect-s.exe hisat2-inspect-l.exe hisat2-repeat.exe
```

`-static -static-libgcc -static-libstdc++` folds the GCC/libstdc++/winpthread
**and zlib** runtimes into each `.exe`, so nothing but stock Windows DLLs is
needed on a clean machine. The Makefile builds with `-g3`; stripping removes
~90% of the size.

### Windows — ARM64  (MSYS2 **CLANGARM64** shell)

Open the **"MSYS2 CLANGARM64"** shell.

```bash
pacman -S --needed \
  mingw-w64-clang-aarch64-clang mingw-w64-clang-aarch64-make \
  mingw-w64-clang-aarch64-zlib  mingw-w64-clang-aarch64-git \
  mingw-w64-clang-aarch64-gcc-compat

mingw32-make ARCH=aarch64 EXTRA_FLAGS="-static"

strip hisat2-align-s.exe hisat2-align-l.exe hisat2-build-s.exe hisat2-build-l.exe \
      hisat2-inspect-s.exe hisat2-inspect-l.exe hisat2-repeat.exe
```

**`ARCH=aarch64` is mandatory here (the emulation trap).** Even in the
CLANGARM64 shell, MSYS2's own `bash`/`make`/`uname` frequently run as *emulated
x86_64*, so `uname -m` reports `x86_64` and the Makefile would pick the x86 SIMD
path — while clang targets aarch64 — giving `error: unsupported option '-msse2'`.
The CLI override wins (`ARCH ?=`). `gcc-compat` supplies the `g++` the Makefile
invokes; the GCC-specific `-static-lib*` flags don't apply under clang/libc++, so
plain `-static` is correct.

### Verify (any platform)

```bash
./hisat2-build-s ref.fa idx
./hisat2-align-s -x idx -U reads.fq.gz -S out.sam    # .gz read directly — no wrapper, no temp
grep -c -v '^@' out.sam                              # expect the mapped-read count
```

Running `hisat2-align-s`/`-l` **directly** is the point of the native-gzip patch:
`.gz` (and plain) reads — from files **or piped on stdin (`-U -`)** — stream in
with no `hisat2` wrapper, no `gzip.exe`, and no intermediate decompressed file.
The binaries are self-contained — check with `ldd` (Linux/Windows) or `otool -L`
(macOS); only system libraries should appear.

### The `hisat2` launcher

Upstream's `hisat2` command is a **Perl** wrapper. This tree ships a
dependency-free **PowerShell** launcher, [`hisat2.ps1`](hisat2.ps1), instead. It
reproduces the wrapper's behavior:

- picks `hisat2-align-s` vs `-l` from the index (or `--large-index`), and the
  `-debug` variant with `--debug`;
- forwards all other options to the aligner (`--wrapper basic-0`); gzip input is
  handled inside the binary, so nothing is decompressed here;
- implements the read-redirection options the align binary does **not** handle
  itself — `--un` / `--al` / `--un-conc` / `--al-conc` / `--al-conc-disc` (and
  their `-gz` / `-bz2` compressed forms) and `--no-unal` — by driving the
  binary's `--passthrough` mode and demultiplexing the reads, exactly as the Perl
  wrapper does (verified byte-for-byte against it).

```powershell
.\hisat2.ps1 -x <index> -1 r1.fq.gz -2 r2.fq.gz -S out.sam
.\hisat2.ps1 -x <index> -U reads.fq.gz --un-gz unaligned.fq -S out.sam
# HISAT2_BIN   dir holding the align binaries (default: script dir, then .\bin, then PATH)
# HISAT2_ECHO  print the constructed command without running it
```

`-gz` redirected output is produced natively (.NET, no `gzip.exe`); `-bz2` (rare)
requires `bzip2` on PATH. As in the Perl wrapper, a compressed output keeps the
plain mangled name (e.g. `out.1.fq` containing gzip data; no `.gz` suffix added).

If you already have **Perl** on the machine (e.g. Strawberry Perl), the original
upstream `hisat2` Perl wrapper also works — it just additionally needs `gzip.exe`
on PATH for its own `.gz` handling, whereas `hisat2.ps1` needs neither Perl nor
`gzip.exe`. Either way you can also skip the wrapper and call
`hisat2-align-s`/`-l` directly.

Index building has a matching launcher, [`hisat2_build.ps1`](hisat2_build.ps1):
it selects `hisat2-build-s`/`-l` (by `--large-index` or reference size), adds the
`.exe` suffix, and runs the binary as a child process so the caller gets the real
exit code — fixing the two POSIX assumptions in the upstream `hisat2-build`
launcher (no `.exe` suffix; `os.execv`, which does not replace the process on
Windows). Same `HISAT2_BIN`/`HISAT2_ECHO` environment variables.

```powershell
.\hisat2_build.ps1 [options] <reference_in> <ht2_index_base>
```

### Known limitations on Windows

- **`hisat2-build` reads plain FASTA.** Reference gzip streaming is not wired up
  (only the read/aligner path is); pass an uncompressed reference, or ship a
  prebuilt index.
- **Non-ANSI (Unicode) paths** are not supported by the narrow-character
  filesystem interfaces.

---

## Patches (vs upstream 2.2.3)

Windows text/line-ending fixes are `#ifdef _WIN32`-guarded; the `auto_ptr` and
native-gzip changes are correct on every platform and are deliberately
unguarded. Output line-ending fixes use `"wb"` / `ios::binary`, which are no-ops
on Linux/macOS, so they too are portable and applied unconditionally.

| File | Change | Reason |
|------|--------|--------|
| `gfm.h`, `hisat2.cpp`, `hisat_bp.cpp` | `std::auto_ptr` → `std::unique_ptr` | `auto_ptr` was removed in C++17 and is gone from newer libc++ (Windows CLANGARM64: `use of undeclared identifier 'auto_ptr'`). Drop-in here (only `.get()` used); future-proofs libstdc++ too. |
| `filebuf.h` | `OutFileBuf` opens output files `"wb"` (all three ctor/`setFile` paths) | Windows text mode rewrites `\n`→`\r\n`; CRLF in a SAM breaks the `hisat2 \| samtools view -b -` pipe (a stray `\r` glues onto the last field). |
| `hisat2_main.cpp`, `hisat2_build_main.cpp`, `hisat2_repeat_main.cpp`, `hisat2_inspect.cpp` | `#ifdef _WIN32`: `_setmode(_fileno(stdout/stderr), _O_BINARY)` at the top of `main()` (+ `<io.h>`/`<fcntl.h>`/`<stdio.h>`) | The piped SAM on stdout and all text logs must be LF-only for the same reason; the pre-opened std streams need `_setmode` even after files are handled. |
| `hisat2_main.cpp` | `#ifdef _WIN32`: also `_setmode(_fileno(stdin), _O_BINARY)` | A `.gz` (or plain) stream piped on stdin (`-U -`) must be read as raw binary, else text-mode CRLF translation corrupts the compressed bytes. |
| `hisat2.cpp` | Alignment-summary and novel-splice-site `ofstream` opened `ios::binary` | Same CRLF fix for the two remaining text sidecar files the aligner writes. |
| `repeat_builder.cpp` | `.rep.*.seed` and the `saveRepeats` outputs opened with `ios_base::binary` | Same CRLF fix for `hisat2-repeat`'s text outputs. |
| `gzip_reader.h` / `gzip_reader.cpp` *(new)* | A thin zlib wrapper (`gzr_open`/`gzr_dopen`/`read`/`rewind`/`close`) behind an opaque handle. `<zlib.h>` is confined to this one translation unit; the header is C/C++-portable (`extern "C"` under `__cplusplus`). `gzr_read` fills its buffer in a loop and checks `gzerror` at end-of-stream. | **Adds native streaming gzip input** with no header-wide zlib dependency. The fill-loop + `gzerror` check is required: a truncated/corrupt stream must fail loudly, not be silently treated as EOF (which would drop the tail of the input and still exit 0). `gzr_dopen` (dup + `gzdopen`) extends the same path to a piped stdin. |
| `filebuf.h` | `FileBuf` gains a 4th backend (`void* _gz`) alongside `FILE*`/`ifstream`/`istream`, wired at the single `peek()` refill point plus `init/isOpen/close/reset/newGzFile` | Routes read input through the zlib reader without disturbing any other `FileBuf` user (index/reference readers keep the untouched `fread` path). |
| `pat.h` | `PatternSource::open()` opens read files via `gzr_open`, and stdin (`-U -`) via `gzr_dopen(fileno(stdin))`; zlib reads gzip **and** plain transparently | Single choke point: gzip decompression happens inside the aligner, so `.gz` reads (from files *or* stdin) need no external step. Only this call site changed. |
| `Makefile` | `gzip_reader.cpp` added to `SHARED_CPPS`; `-lz` added to `LIBS` | Compile/link the zlib reader into every binary. `-static` folds `libz.a` in on Windows. |
| `Makefile` | Disable `BOWTIE_MM`/`BOWTIE_SHARED_MEM` when `$(OS)==Windows_NT` | Upstream only disables them when `uname` contains `MINGW`, which misses MSYS2 **CLANGARM64** (`uname`→`CLANG*_NT`) and any build driven from an MSYS/SSH shell (`MSYS_NT`); otherwise `reference.h`/`gfm.h` pull `<sys/mman.h>` (absent under MinGW) and the build fails. Keying off the shell-independent `$(OS)` fixes it. Verified on the ARM64 VM. |

### Patch layout and maintenance

All portability source and build changes are contained in this tree. Keep edits
minimal and concentrated, `#ifdef _WIN32`-guarded where they are genuinely
Windows-specific, and prefer isolating new functionality in its own translation
unit over threading it through shared headers:

- **New functionality lives in its own unit.** `gzip_reader.{h,cpp}` holds all
  zlib code; `filebuf.h` sees only an opaque `void*` and four function decls, so
  `<zlib.h>` never enters the broadly-included headers.
- **Integration edits stay at one choke point.** Gzip input is wired in only at
  `FileBuf::peek()`'s refill and the single `pat.h` open site; no other read-file
  call site changed.
- **Line-ending fixes** use `"wb"` / `ios::binary` (portable no-ops off Windows)
  plus one `_setmode` block per `main()`. They are not hidden behind broad macros.
- **`auto_ptr` → `unique_ptr`** is a direct, unguarded modernization.

The from-scratch build runbook (toolchain install, the `auto_ptr`/CRLF perl
one-liners against a *fresh* upstream clone, ARM emulation trap, static-link and
strip details, and the CRLF regression guard `check_hisat2_crlf.sh`) is in
[`../WINDOWS_BUILD.md`](../WINDOWS_BUILD.md) §3.

---

## Redistribution & licensing

The Windows recipes above produce a **static** binary intended for personal use.

- **Own use:** the static binary is fine as-is.
- **Redistributing the binary:** HISAT2 is **GPL-3.0**; bundle its license and
  source (or a written offer) along with the notices of everything compiled in —
  zlib, and on Windows the statically linked GCC/libstdc++/winpthread runtimes.
  The simplest way to satisfy the runtime-relink terms is to build **without
  `-static`** so those become replaceable DLLs, then ship each DLL's license.
