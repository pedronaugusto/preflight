# Preflight design

Preflight owns repository gates, build and process orchestration, and the canonical hosted workflow planner. Gantry owns semantic architecture checks. Code-level rules belong to glint, which preflight runs for the repository: which files, with which imports and under which policy are preflight's; what a rule finds is glint's.

## Code rules

Preflight runs glint as a library in its own process, in one in-memory project, not as a child process. A child would need a result protocol to be told from a crash, and the repository's path dialect (which files are test code, which a vendored fork, which have a lower function ceiling) has no surface in a command line that treats every file alike. In-process, a file that cannot be read is an error, a panic is a failed step, and the verdict is read from the report itself, so no outcome has to be recovered from text or a receipt. The cost is that glint's runtime, and aegis under it, is built for every repository's checks.

Files are the repository's `glint_paths`, or the shipped `sources` and the directories a repository keeps code in beside them. Selection is separate from `sources` because `sources` is the set `.paths` ships and must list; a benchmark is gated without being shipped. Every import is resolved from the build's configuration, the same facts the structure and toolchain checks use: `std` from the compiler's library, a relative path as itself, a named module as the configuration binds it in each module that compiles the file. A name two modules bind to different files, or none binds, stays unresolved, never guessed. The cost is one read of every file the selection imports, standard library included, once per run.

The policy is the group review's. Z026 (a discarded error needs its reason) gates: a discarded error is a result nobody read, and by 2026-10-15 every package of the family had written a reason at each of its own (decided 2026-10-10, gated once the family was clean). The style rules are reported, and a package gates each as it becomes clean, the review's order reported, then gated. glint's `gate` couples two things: a finding fails, and a site the rule could not decide makes the run incomplete. That is right for a rule that can decide every site it names (a cast, a discarded error, a function's length) and for the aegis rules, which a repository adopts knowing what they cannot see. It is wrong for deprecated calls and debug prints: glint resolves a call through a receiver of unknown type to nothing, and a run that must resolve every call never completes. Those two are *findings* in the default policy: glint reports them, any finding fails, and the calls it could not resolve are counted and are not a verdict. A repository may still gate them in glint's sense by naming them.

A run is complete or it is not a pass. The run fails on a file that does not parse or lower, on an exhausted fact budget, on a site a gating rule could not decide, on a file that cannot be read, and on a suppression that suppresses nothing (the default; a repository may turn it off). A finding the policy allows never hides one of these. This closes the review's finding F04, which the ziglint fork could not close: it had no outcome for an analysis that stopped. There is no profile to select: the default policy is preflight's, a repository amends it rule by rule, and a setting preflight cannot honour fails by name rather than turn a gate off.

Exceptions are glint's inline `glint-ignore` with a reason, one site each. The exact-match ledgers (`ziglint_exceptions`, `unreachable_exceptions`, `debug_print_exceptions`) and their shrinking budget retire with the tool they were for. A retired key fails the repository that still names it.

## Configured builds and target projection

`addCi` consumes the caller's actual `std.Build` graph. Foreign target checks project configured artifacts to objects, including test, helper, benchmark and transitive native-source modules. Native `ci-link` and portable test-build steps retain the original artifacts and their SDK libraries/frameworks. Object compilation certifies compilation; only native linking and execution certify those operations. Benchmark modules include the selected ordinary graph, which `ci-check` compiles in Debug, and the separate ReleaseFast graph, which `ci-check-bench` compiles: a benchmark's optimizing compile outweighs every other object of its target, so it is the release tier's.

The checks are one binary per runner kind, built once per commit by `zig build toolchain` and passed to every job and to the build as `-Dci-checks`; a build without the option compiles them from source (`tool.zig`). One job per run owns the build, so the only compile of the checks in a run is the one a commit has not had yet.

The `facts` adapter asks the installed Zig 0.17.0 compiler/build runner to configure through `zig build --listen=-`. Build-system handshake version 1 and configuration notifications differ from compiler messages. The serialized configuration is read while the child lives, then the supported exit message ends the session without requesting artifact execution. Both compiling and invoked compiler versions are exact gates; this native internal format is not a stable external API.

Facts preserve configured module identities and scoped imports, step dependencies and artifact/test roots, package owners, options, lazy dependencies, generated/source path identities, target flags and native framework requests. They describe the configured artifact graph, not the compiler's analyzed source-level graph. Gantry declarations remain its owner. Lint reads these configured test roots, the root files of test artifacts some run under a step CI runs runs (a test artifact only compiled holds tests that never run, and fails the lint by name), and embedded WriteFile source content; unavailable dynamic producer content fails clearly when required. It never substitutes the old handwritten root reconstruction. CLI configuration options are replayed; unsupported non-CLI inputs fail rather than implying parity.

The adapter validates native serialized storage before calling std's loader. Frames are bounded to 64 messages and 8 MiB each; paths/strings to 32 KiB; protocol accumulation, each child capture stream and the configuration file each to 64 MiB. Validation limits traversal to one million words/references and depth 64, with deduplicated references. I/O inactivity is bounded to 120 seconds. Unknown messages, wrong versions, malformed indices/tags/flags, truncation, cancellation, child signal/nonzero exit and reader/writer failures are infrastructure failures. None falls back to guessed facts.

## Measurement ownership

`Config.bench` configures ReleaseFast programs, injects the published shakedown module and actual commit/physical host CPU/OS provenance, and installs shakedown's comparator. Callbacks describe work and observable results. Shakedown owns warmup, clock resolution, batching, samples, statistics, JSONL and noise comparison. Preflight owns artifact builds and child processes; it implements no timer or statistical algorithm.

`bench-build` only builds. `bench` explicitly measures. Local `test` runs each program once with `--smoke`, invoking each row once; ordinary hosted CI disables those executions and compiles benchmarks. `bench-ab` requires a clean candidate and a caller-selected immutable base/program/row, builds the detached base in owned temporary storage, and alternates base/candidate order with fresh working directories. Both revisions must implement the benchmark contract; earlier revisions fail rather than being patched. Provenance is checked against actual commits and Zig. Invalid inputs, signal/nonzero exit, malformed/truncated JSONL, smoke output, capture/output failures and child timeout fail infrastructure. Capture is bounded to 64 MiB per stream and execution to 600 seconds. Comparisons report changes and noise without timing pass/fail thresholds.

## Hardened profile

Every package runs it (aegis's design §7); `Config.hardened` chooses its steps, and a package with nothing to fuzz names `.fuzz_step = null`. Selected test artifacts retain Debug or use ReleaseSafe, with LLVM selected for native instrumentation. Normal builds retain caller-selected modes. Safety remains on; any source loop exception requires its own measured justification. This design does not force startup allocation policy onto callers or police source text with regexes.

`hardened` executes tests. `hardened-fuzz` executes Zig 0.17's bounded native fuzzer on eligible 64-bit non-Windows hosts, through `preflight fuzz-campaign`: Zig exits 0 from a bounded campaign whose fuzzer crashed, so the campaign is judged on the cache it ran on, failing on an input saved to `f/crash` during the run or on coverage that counts no new run. Dedicated test steps must execute tests, and absent fuzz tests fail the campaign. Callers supply seeds through std.testing.fuzz; Zig owns corpus, failing-input reproduction and instrumented coverage. Hosted jobs retain the actual configured local-cache fuzz directory for seven days, including on failure. Reported campaign coverage is not a comprehensive-coverage guarantee.

`hardened-tsan` executes LLVM ThreadSanitizer tests only on native x86_64 or aarch64 Linux or macOS; every selected module must be eligible. Unsupported hosts and sanitizer startup failures fail explicitly. The test runner keeps std.testing.allocator and std SafeAllocator's checks (leaks, double frees, footers, write-after-free) and, in the hardened run, backs it with the package's own shakedown's quarantine instead of the page allocator: a mapping per block with an inaccessible page after it, whose address is never handed out again, one quarantine per test. A block SafeAllocator takes whole (past three quarters of its bucket size) then faults at the line on a read or write after free, and a bucket once all of it is freed; a lifetime bug fails the same way every run. The runner imports the package's shakedown as `preflight_quarantine`, the one the test module's graph holds when it holds one, so it is the one copy, else the one the package declares; the merge tier keeps the page allocator. Regression consumers exercise an actual freed-storage write and read and, on Linux, a real intentional race alongside a synchronized control.

## Canonical orchestration and costs

One Zig planner owns every workflow tier and matrix; callers regenerate through `zig build plan`. A macOS target's link runs on a Mac only when the build configured for that target links a framework, which only Apple's SDK holds; `plan` and `gate` read that from the build (`sdk_targets` beside the configuration, as `measured` is), and Zig links any other macOS program on Linux with the libSystem it ships. CI controls have one declaration owner, including early root lazy-discovery returns. A caller-provided `Config.timings_enabled` retains its existing option ownership: preflight uses that value without declaring a second `ci-timings` option. Declarative repository facts stay with the caller. The hardened profile adds three native jobs to every package's release tier; ordinary planning adds one option lookup. The hosted runner queries compiler-derived available options before injecting benchmark smoke control, preserving older custom steps that never declare it. That costs one configure-only request per execution. Serialized validation scales with configured storage and references, outside package runtime hot paths. Matched measurements belong in private trials beside their driver; correctness and required safety checks are retained regardless of their cost.

Runner protocol, timeout, test ordering, allocation ownership and portable shard records remain separate from benchmark measurement. The runtime build dependency closure remains unchanged; shakedown is lazy test/benchmark support. Configuration and driver fault tests use deterministic child/input/output failures, rather than timing thresholds.


Cross projections retain each compile step's expected-error union and diagnostic limit. Zig's build runner owns matching (`contains`, `exact`, `starts_with`, `stderr_contains`) and failure outcomes. Deliberate failures do not request emitted binaries, since Zig returns after matching rather than producing a file. Positive projections still emit objects; original native artifacts retain their diagnostic and SDK-link contracts. The integration fixture exercises expected failures, wrong diagnostics and unexpected success across Linux, both macOS architectures and both Windows architectures, with a positive object beside each rejection.

## The linked graph and tooling

A package has two graphs. The linked graph is what its artifacts link; tooling edges are what
only its CI uses (the checker, test support it pins), lazy, so a project depending on the
package never fetches them. A tool is a program that reads the package and links none of it,
so it may be built with any revision of anything, the package itself included: a tool checks
itself with the revision of itself it pins, and a library it uses moves without waiting for it.
The pins of the tooling graph may therefore form cycles; the linked graph may not.

`lint` holds every artifact the package's build configures to one revision of each package, the
package under test included, and to no cycle between packages. A package cannot pin its own
commit, so a cycle back to it always shows as a second revision of it; a dependency given the
package's own module (test support built on its types, which bay gives the package under
development) is one copy, and is neither. Programs built from another package's sources are that
package's tools and not counted. The check reads Zig's configuration of the build, by package
hash and module import table, not manifests, so a revision that an injected module or a
dependency's pin brings is seen where it is linked. A family of packages whose tools check each
other stays a DAG to every consumer this way, and its moves are a release train: re-pin in
dependency order, each released on its own green gate (`bay --workspace release`).

What preflight adds to an artifact obeys the same rule. The test runner, its shard order and its
watchdog link std alone; benchmarks and fuzzing measure through the package's own shakedown,
declared by the package. Nothing of preflight's pins reaches a package's artifact.

A `build.zig` function that calls `lazyImport` raises the branch quota before it: std compares every package of the tree at comptime, so the failure depends on the size of the tree and not on the code, and it appears in whichever function calls it. `lint` reads the function bodies and reports the call with no earlier `@setEvalBranchQuota`.

A nested manifest (a fixture's, a conformance build's) pins each package the root also pins
exactly as the root does; the check names the drift. A fixture generated at build time from the
root's dependency cannot drift at all: `addConsumerCheck` writes its project under the cache, and
`addNestedBuild` assembles a build whose sources live in the tree under the cache, its manifest written
from the root's own pins when the build is configured, and runs it there: the tree holds no output.
The lint check stays as the backstop for a manifest kept by hand.

## Releases are verified, not made

A package releases with bay (`bay release`): bay owns versions, pins and the release train, so it
writes the release from the changelog, commits it, and tags and pushes it once a gate passed on
that commit. preflight verifies. Its gate checks, before any job, what a release needs beside the
jobs: the caller as `plan` generates it, the manifest's version as the changelog's newest release,
and the changelog against the API diff since the last `v*` tag, so a removed or changed public
declaration that the changelog does not call breaking is refused, never bumped silently. The lint
checks the last two on every commit. The changelog is read with bay's own reader of it, so the
checker reads what the writer writes. preflight is run through the package's development build,
not linked into bay: the preflight that judges a package is the one its manifest pins.

## Generated caller

The caller is generated whole from `ci/workflow.json`: the gate call with every tier's matrices,
the package's declared jobs among them, the triggers and the concurrency groups. A package's own
job is a build step with hosts, tiers, a directory and a setup step, run by the gate's job with
its setup and caches, so its refs, inputs and `needs` cannot go stale and a change waits for it
like any job of the gate. The generator refuses to replace a caller holding a job the
configuration does not declare. Nothing in a caller writes: it asks for read alone.

## The runner's streams

Zig's Run step serves the test runner its protocol on the runner's stdin and stdout, and
ends the runner only when both its stdout and stderr reach their end, allowing 60 s of
silence outside a test. Every process a test starts inherits those streams unless the
test says otherwise, so one still running after the last test held the build's end open
and the build killed the runner a minute later, outside any test and past the watchdog;
one that read its stdin took the protocol's bytes, and one that wrote its stdout wrote
into it. Serving the build, the process the build starts (the supervisor) starts the
tests' process with its own stdin and stdout and a pipe as stderr. That process moves
the protocol to descriptors (handles, on Windows) no child inherits, takes the null
device as stdin and its stderr as stdout. The supervisor forwards the pipe to its own
stderr while it waits for the tests' process, so what that process wrote, a crash's
report included, is in the pipe before its ending is seen: once it has ended, the
forwarding stops, its read canceled through `std.Io.Batch`, which still yields a read
that completed as it was canceled, and never between a read and its write; the rest is
read until the pipe ends. A process that still holds the pipe two seconds after the
last byte is named (Linux: the descriptors in `/proc`; macOS: libproc's pipe peers) and
fails a run that would have passed. The tests' ending becomes the supervisor's: its exit
status, Windows' whole, or its signal raised again. The tests' process ends with the
supervisor however that ends (the build kills the process it started when a test
outlasts a `--test-timeout` given by hand): it holds the read end of a pipe whose write
end only the supervisor holds, and a thread of its own ends it when that pipe ends. The supervisor takes threads and a
spawn, so a single-threaded build or a system that cannot start a process runs the
tests in the one process, with the protocol still moved.

## Shard and watchdog boundaries

`Shard.init` and `Shard.parse` establish a nonzero count and an index below it.
`assign` rechecks those contracts because Zig permits direct field construction,
checks that `count * sizeof(f64)` fits before load allocation, and rejects unequal
name/weight lengths before allocating or indexing. The modules link std alone: they
are compiled into every package's test binaries, where any package they imported could
be a second copy beside the package's own.

The build helper retains `std.Io.Duration` through `TestTimeout.duration`, validates
the generated options' `u64` nanosecond range and exports that schema once; the runner
reads it back as a `std.Io.Duration`. The disabled
watchdog remains zero; nonpositive custom durations retain their one-nanosecond
floor. Missing reasons and oversized custom durations fail configuration.

The watchdog owns an awake-clock deadline and only observes an atomic completion
flag. The test thread publishes completion, wakes it and joins before reclaiming
storage. There is no lock beside borrowed data: a spin guard cannot implement this
futex publication/wait protocol. Std clock-tagged timestamp comparison and timeout
values keep clock and scale together.

Under the build runner's protocol a passing test run and a passing lint write nothing: Zig 0.17
shows any stderr of a passing build step under a "failed command:" line. A failure names its
seed, and lint prints all it held when it fails.

## The FreeBSD test machine

A program built for x86_64 FreeBSD runs on FreeBSD's own kernel under QEMU with KVM, on
an x86_64 Linux host only (vm/freebsd.zig refuses any other by name); it is the nightly tier's,
for what no hosted runner is and a cross-compile cannot show: FreeBSD's kernel TLS and
its sockets. The machine is FreeBSD's own release files, pinned by hash in preflight's
manifest and fetched only by a build that asks for it, as the riscv64 machine's Alpine
files are: the kernel distribution set (`kernel.txz`) and the runtime OCI image, whose
one layer is the base system a program needs (`ld-elf.so.1`, libc, libthr, `sh`).

There is no loader. The release's `base.txz`, the one archive holding `loader.efi`,
cannot be a dependency (below), and pkgbase's `.pkg` files are not an archive type Zig
fetches. QEMU starts the kernel at its PVH entry (`-kernel`; FreeBSD's amd64 kernel
carries `XEN_ELFNOTE_PHYS32_ENTRY`) with its environment on the command line:
`vfs.root.mountfrom`, `init_path`, the serial console and its port's hints. A PVH
boot keeps none of the command line's flags, only its variables, so the serial console is
`boot_serial=YES` (`-h` would be dropped and vt, outranking the uart, would take the
console to no display). The
processor's TSC is invariant (`-cpu host,+invtsc`): a PVH boot sets FreeBSD 15.1's early
`DELAY` to Xen's, which reads Xen's shared page, NULL on KVM, so the console's first
`DELAY` faulted and the boot ended in a double fault before printing; with an invariant
TSC whose frequency QEMU reports, `DELAY` counts the TSC instead. Without a loader no module is
preloaded, so the root is a file system GENERIC builds in: an ISO 9660 image with Rock
Ridge (vm/iso9660.zig, cpio.zig's counterpart) that the host writes from the layer's
members as they are (modes, owners, symbolic and hard links), the kernel and its modules
under `/boot/kernel`, and preflight's first process at `/preflight/init`
(vm/freebsd/guest.zig), which loads the modules the run needs from there
(virtio_console, virtio_p9fs, nullfs). The writer is checked against libarchive's
reader on FreeBSD's own layer, member for member, and against FreeBSD's cd9660 by the
machine's every boot.

A run is the riscv64 machine's: the host writes it in a directory shared over 9p (the
program, its arguments and environment, the directories it names, its scratch
directory, its user), and the program's stdin and stdout are a virtio port, its stderr
another, its ending a third. The ISO root cannot be written, so the program's root is the
machine's memory: the first process mounts a tmpfs, nullfs-mounts FreeBSD's system
directories into it read-only (`bin`, `boot`, `etc`, `lib`, `libexec`, `sbin`, `usr`),
and gives it its own devfs, `/tmp` and `/var/tmp`. The run's share and the host's are
mounted outside it, at directories of the ISO image (`/preflight/run`,
`/preflight/host`); the host's directories are made at their host paths in it and bound
there from the host's share (one inside another already bound is there already: nullfs
refuses it, `EDEADLK`), and the scratch directory is a tmpfs of its own. Only then does
the first process take it as its root, so the program reaches the host's directories
it names and no other, as on the riscv64 machine, which detaches its share.
FreeBSD's virtio ports are terminals,
which drop what arrives before they are opened and mangle it until they are set raw, so
the first process opens them raw and writes `started` to the status port, and the host
sends the program's input only after it. `started` ends the one deadline the machine
has of its own (180 s, the boot); the program after it is bounded as it is on any host,
by the test runner's watchdog. Every way a run ends is named: the program's exit code
or signal (FreeBSD's number, which the host ends by under Linux's number for that
signal, or by 128 plus it for one Linux has not), the first process's error, a panic
on the console, the deadline, or QEMU ending without any of them; for all but the
first, the run's directory is kept, its console among it, and the console's last lines
are written to the build's output. A FreeBSD run on a host other than x86_64 Linux is refused
when the build is configured, naming `ci-vm=freebsd`, and one on a Linux host without
KVM open to its user when it runs. vm/freebsd/probe_test.zig is the machine's own
proof: tests built for FreeBSD and run on it through this path (`zig build
-Dvm-freebsd-probe vm-freebsd-probe`), skipped on every other system.

Rock Ridge readers disagree on a symbolic link whose SL entries split between two
components (libarchive starts each entry without a `/`; FreeBSD follows the last
component's continue flag), so the writer ends an entry only inside a continued name,
where both agree, and refuses the rare target it cannot split that way.

**A gap in Zig 0.17.0: tar hard links.** Zig's package fetch fails on any archive with a
hard link (ustar type `1`), and `std.tar.Iterator` skips one, reporting it as
unsupported without its target. FreeBSD's `base.txz` has 13,021 of them (`/rescue`,
`/bin/[`), so it cannot be a dependency; the OCI image's outer archive has none, and
the host reads the layer inside it with its own reader (vm/ustar.zig), which keeps them.
The repro, two members:

    printf 'x\n' > a && ln a b && bsdtar --format ustar -cf one-hardlink.tar a b
    zig fetch one-hardlink.tar
    # error: unable to unpack tarball
    #     note: file 'b' has unsupported type '1'

When Zig's fetch takes hard links, `base.txz` could replace the OCI image and bring
FreeBSD's loader with it; the ISO root and PVH boot would not need to change.
