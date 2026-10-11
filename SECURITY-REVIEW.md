# OpenDisk — Security & Bug Review

**Fork:** `banterny/OpenDisk` (upstream `137137137/OpenDisk`, MIT)
**Reviewed at:** upstream commit `7295c84`
**Review date:** 3 August 2026
**Platform:** macOS 26 (Tahoe), Swift 6, ~6,500 lines of app code + ~1,100 lines of tests
**Toolchain verified:** macOS 26.5 / Xcode 26.6 — the app target builds clean.

## What this app actually does

OpenDisk is a disk-usage analyser that **permanently deletes files**. Two
distribution builds share one codebase:

| | Website build | Mac App Store build |
|---|---|---|
| Sandbox | **off** | on |
| File access | Full Disk Access (whole machine) | user-granted folders via security-scoped bookmarks |
| Auto-update | Sparkle 2.9.4 | App Store |

The security surface that matters is therefore: (1) what can be deleted,
(2) what code ends up running, and (3) the raw C filesystem interop.

## Summary

| Category | Status | Issues |
|---|---|---|
| Code integrity / updates | ❌ | 1 critical |
| Deletion safety | ❌ | 1 critical, 4 high |
| Filesystem interop (memory safety) | ⚠️ | 1 medium, 1 low |
| Cache / persistence | ⚠️ | 2 medium |
| Sandbox detection | ⚠️ | 1 medium |
| Build & signing | ✅ | 1 withdrawn (Hardened Runtime already on) |
| Test suite | ❌ | does not compile upstream |
| Network / credentials | ✅ | no network I/O, no credentials, no secrets |

**Overall risk before fixes: High.** Not because the code is careless — it is
unusually well engineered and heavily commented — but because a permanent-delete
tool with an auto-updater has two failure modes with no undo.

---

## 🔴 Critical

### C1. The reviewed fork replaces itself with a third party's binary

**File:** `OpenDisk-Info.plist:9-12`, `OpenDisk/App/OpenDiskApp.swift:19-25`

```xml
<key>SUFeedURL</key>
<string>https://opendisk.app/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>269Oo3e4gnIe1gwQ8c9XZNoHZp1JAG4ofd3Kad6+V5A=</string>
```

`SPUStandardUpdaterController(startingUpdater: true)` starts Sparkle at launch.
Sparkle's defaults check the feed automatically and, on the user's approval,
download and install whatever `opendisk.app` serves, validating it against
upstream's EdDSA public key.

**Why this is the headline finding:** it defeats the entire purpose of forking
and reviewing. You build the audited fork, run it, and within days the running
binary is upstream's unaudited build — signed by a key you do not hold, fetched
from a domain you do not control, installed with no further prompt beyond
"Install Update". Every fix in this document would be silently reverted.

The transport itself is fine (HTTPS + EdDSA signature). The problem is the trust
relationship, not the mechanism.

**Related:** `MoveToApplications.swift` compiles only when Sparkle is linked, and
it spawns `/usr/bin/xattr -dr com.apple.quarantine` (`:101-107`) and `/bin/sh -c`
(`:112-116`) on the app bundle. Neither is injectable — arguments are passed as
`argv`, not interpolated into a shell string — but stripping quarantine from a
bundle it just copied is exactly the behaviour you do not want in a build whose
provenance you are trying to pin down.

**Fix applied:** Sparkle removed entirely — SPM package dependency, link phase,
both `Info.plist` keys, and the code behind `#if canImport(Sparkle)`. The fork
updates by `git pull` + rebuild, which is the only update path whose contents
you can actually read first.

---

### C2. Protected-path guard is bypassable via the Data-volume firmlink

**File:** `OpenDisk/Services/ProtectedPaths.swift:26-52`

`ProtectedPaths` is the sole guard preventing the Collector from deleting the
system, your home folder, or `~/Library`. It normalises with
`NSString.standardizingPath`, which does **not** resolve firmlinks or symlinks.

Verified on this machine:

```
$ stat -f '%d %i' "$HOME"
16777231 399511
$ stat -f '%d %i' "/System/Volumes/Data$HOME"
16777231 399511        # same device, same inode — the same directory
```

`ProtectedPaths.reason(for: "/System/Volumes/Data/Users/anthonysearle")` returns
`nil`, because:
- it is not string-equal to `/Users/anthonysearle`;
- its parent is `/System/Volumes/Data/Users`, which is not in the `/Users`,
  `/Volumes`, `/System/Volumes` parent switch;
- no `systemRoots` entry has it as a prefix.

So the entire protection set — home, `~/Library`, `/System`, `/Library`,
`/Applications`, every user account — is bypassable by prefixing
`/System/Volumes/Data`. Deleting that path deletes the real home folder.

**Reachability — this is the important part, and it needs H4 to be read first.**

In the ordinary flow this prefix does not reach the Collector on its own.
`ScanEngine.resolveDataVolumeAlias` (`ScanEngine.swift:233-237`) does construct
`"/System/Volumes/Data" + path`, but only for `scanPath`; `rootName` keeps the
original, so `FileTree.path(of:)` emits normal paths. That route is weak.

The real chain is **C2 combined with H4**:

1. A crafted payload arrives on the drop target (H4 — `public.json` is a
   system-wide type, so any dragged `.json` file or any application can supply
   one) carrying `path = "/System/Volumes/Data/Users/alice"`.
2. `ProtectedPaths.reason` returns `nil` (C2 — the guard doesn't know that name).
3. `Collector.appendOne`'s `fileExists` check *passes*, because the path is real.
4. The row appears in the tray showing the innocuous name `alice`.
5. One confirmation dialog later, the home folder is permanently deleted.

Neither finding is critical alone: C2 needs something to supply the unusual path,
and H4's payload is normally stopped by the protection check. Together they form
a complete path from "user drags a file into the app" to "home directory gone".
Both are fixed, and either fix alone breaks the chain — which is why both were
made rather than picking one.

**Fix applied:** the guard now checks three forms of every path — the literal
normalised one, the `resolvingSymlinksInPath` form (which *does* collapse
firmlinks; verified directly), and, for a path that doesn't exist and so can't
be resolved, the form with a leading `/System/Volumes/Data` stripped. Any one of
them matching refuses the path. `normalized()` itself is unchanged and still
string-only; the new work lives in `canonicalForms`/`canonical`.

Resolution is memoised: `reason(for:)` now touches the filesystem, and
`FileActionsMenu`/`FolderRowView` call `isProtected` while building each row's
context menu, so an unmemoised version would cost one `realpath` per visible row
per render pass.

Five new tests in `ProtectedPathsTests`; 9 assertions fail against the original
implementation and pass against this one. No existing test was modified.

**I got this fix wrong once.** My first version applied the "is this on a system
volume?" rule to *every* form including the literal one, which meant that under a
scan rooted at the Data volume — precisely what the sandboxed build's open panel
returns when the user picks "Macintosh HD — Data" — every row wore the
`/System/Volumes/Data` prefix and *every deletion was refused*. Caught by adding
the missing test in the other direction ("Data-prefixed ordinary files are still
deletable", 4 failing assertions). The rule now runs once, against the resolved
path only. Recorded because a guard that silently refuses everything is a real
regression, not a harmless excess of caution.

---

## 🟠 High

### H1. Deletion is permanent, irreversible, and reports invented numbers

**File:** `OpenDisk/Models/Collector.swift:150-182`

```swift
try FileManager.default.removeItem(atPath: file.path)   // :165
...
freed += file.size                                       // :171
```

`removeItem` is an unlink, not a move to Trash. There is no undo — the code says
so (`:179-180`, `undoStack.removeAll()`). A single confirmation dialog stands
between a mis-drag and permanent loss of, say, `~/Documents`.

Separately, `freed += file.size` adds the size **the scan recorded**, not what
was actually reclaimed. That figure is wrong whenever:
- the directory changed between scan and deletion (the scan may be minutes old);
- the subtree contains hard links whose bytes the dedup logic attributed
  elsewhere (`TraversalScanner.swift:197-215`) — very common under
  `~/Library/pnpm/store`, which is in the "safe to clear" catalogue;
- deletion partially failed inside a directory (`removeItem` is not atomic;
  a partial failure still throws, so those bytes are counted as *not* freed even
  though some were).

**Fix applied:** the user-facing default is now `trashItem(at:resultingItemURL:)`,
with a Settings toggle for permanent deletion (off by default). When trashing,
the tray says "Moved to Trash" rather than claiming space was freed — because it
wasn't, until you empty it — and the host is told zero bytes were reclaimed so it
cannot report a false gain. `deleteAll` also re-checks `ProtectedPaths`
immediately before each removal, closing the window between collect-time and
delete-time.

One deliberate wrinkle: `deleteAll(using:)`'s *parameter* default stays
`.permanent`, so the two existing deletion tests keep exercising the behaviour
they were written for and keep running hermetically instead of filling your
Trash on every test run. `CollectorBar` reads the preference and passes the mode
explicitly, so the safe default applies everywhere a person is involved. No
existing test was modified anywhere in this review.

The stale-byte-count problem is *not* fully fixed — `freedBytes` still comes from
the scan. It is now only ever labelled "freed" in the permanent-delete path,
where it is at least the right kind of claim; making it exact would mean
measuring each subtree again immediately before removal, which doubles the cost
of a delete for a cosmetic number.

### H2. `Xcode Archives` listed as a safe-to-clear cache

**File:** `OpenDisk/Models/HiddenSpace.swift:51`

```swift
Location(name: "Xcode Archives", path: home + "/Library/Developer/Xcode/Archives"),
```

The file's own doc comment promises "nothing whose loss changes user-visible
state beyond a slower next launch" (`:18-20`). Xcode archives contain the
`.xcarchive` and **dSYMs for every build you have shipped**. They are not
regenerable — losing them means you can no longer symbolicate crash reports from
released versions, or re-export/re-sign a submitted build. This is user data
filed under "cache".

**Fix applied:** removed from the catalogue.

### H3. Deletable system-volume contents under `/System/Volumes`

**File:** `OpenDisk/Services/ProtectedPaths.swift:26-33`

`/System/Volumes/Preboot` is protected (its parent is `/System/Volumes`), but its
*children* are not. `/System/Volumes/Preboot/<UUID>` holds the boot
loader and recovery payload for the volume group; deleting it renders the Mac
unbootable. `ScanEngine.scanBootVolumeGroup` (`ScanEngine.swift:442-455`)
deliberately scans and displays these volumes, so their contents are on screen
and draggable.

**Fix applied:** the whole subtree under any `/System/Volumes/<volume>` is now
protected, not just the volume root.

### H4. Drop target accepts `public.json` from any source

**File:** `OpenDisk/Models/CollectedFile.swift:32-38`, `OpenDisk/Views/Analysis/DiskAnalysisView.swift:416`

```swift
static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .json)   // ← public.json, a system UTI
    ProxyRepresentation(exporting: \.url)
}
```

`public.json` is not an app-private type. Any `.json` file dragged from Finder,
or any payload another application places on the drag pasteboard as
`public.json`, is offered to `dropDestination(for: CollectedFileGroup.self)` and
decoded straight into deletion candidates. The attacker controls `path` entirely.

**Severity is bounded, not critical**, by three existing mitigations: the drop
handler re-checks `ProtectedPaths` (`DiskAnalysisView.swift:426`), `appendOne`
requires the path to exist on disk (`Collector.swift:62`), and the collected
names are visible in the tray behind a confirmation dialog. Worst realistic case
is a plausible-looking row like `Documents` that the user confirms.

*Not empirically confirmed:* I did not drive a live Finder drag to prove the
payload is offered. The reasoning is from the declared UTI, and the fix is cheap
enough that confirming first was not worth it.

**Fix applied:** a custom exported UTI, `app.opendisk.collected-files`, declared
in `Info.plist` and conforming to `public.json`. The drag payload now uses that
type, so a plain `.json` file no longer matches the drop target. In-app drags are
unaffected.

**Superseded, Oct 2026 — now stronger than the fix above.** The private type
only ever kept *accidental* payloads out: a type identifier is a string, and a
hostile app can write any string to the drag pasteboard. With the drag rewrite
ported from upstream (`e9a1158`, `43e4967`) the drop target no longer decodes
a payload at all. `InAppFileDropDelegate` accepts a drop only while
`FileDragSource.shared.activeFiles` is set — in-process state that exists only
during a drag begun in this app — and takes the files from there. A foreign
drag fails validation whatever types it advertises. The private type survives
only as the pasteboard marker for drags that carry no file URL.

---

## 🟡 Medium

### M1. Corrupted scan cache hangs the app forever

**File:** `OpenDisk/Services/Scanning/FileTree.swift:282-291`

`rollUpDirectorySizes()` walks the sibling chain unbounded:

```swift
var child = nodes[Int(current)].firstChild
while child != Self.noNode {                  // ← no bound
    if !visited[Int(child)] { visited[Int(child)] = true; stack.append(child) }
    child = nodes[Int(child)].nextSibling
}
```

The `visited` bitmap guards the *stack*, not the sibling walk. A `nextSibling`
cycle loops forever. Every other sibling walk in the file (`childCount`,
`children`, `child(of:named:)`, `path(of:)`, `reachabilityBitmap`) is explicitly
bounded by `remaining`, and the comment at `:152-157` says so — it names
`rollUpDirectorySizes` as "already guarded", but it is not.

Reachable because `init?(serializedData:)` (`:460-476`) validates index *ranges*
but not acyclicity, and the cache is a plain file in
`~/Library/Caches/ideals.OpenDisk/ScanCache/*.dmscan` — writable by anything
running as you, and corruptible by an unclean shutdown mid-write.

**Fix applied:** bounded the walk, and `adoptSubtree`'s equivalent walk, the same
way as the rest of the file. Test added.

### M2. Incremental scan cache grows without bound

**Files:** `OpenDisk/Services/Scanning/IncrementalUpdater.swift:102`, `FileTree.swift:87-96`, `354-404`

`removeAllChildren` intentionally leaves orphaned subtrees as "unreachable
garbage nodes". `serializedData()` writes **all** `nodes.count` entries,
reachable or not. So each incremental rescan splices in new nodes, orphans the
old ones, and persists both. Across many rescans the `.dmscan` file and the
in-memory tree grow monotonically with no compaction step — in a disk-usage
tool, which is an unfortunate place to leak disk.

`ScanCache.prune` caps the *directory* at 8 files / 4 GB but never compacts an
individual tree.

**Fix applied:** the tree is compacted (garbage nodes dropped, indices remapped)
before serialisation.

### M3. Out-of-bounds read on a negative name offset

**File:** `OpenDisk/Services/Scanning/SystemInterop/BulkDirectoryReader.swift:152-159`

```swift
let nameDataOffset = Int(record.loadUnaligned(fromByteOffset: 24, as: Int32.self))
let nameStart = 24 + nameDataOffset
guard nameLength > 0, nameLength < 1_024, nameStart + nameLength <= length else { return }
let namePointer = record.advanced(by: nameStart)
```

`nameDataOffset` is signed and unvalidated. A negative value passes the upper
bound check and `advanced(by:)` reads *before* the record — potentially before
the buffer. The kernel does not produce negative offsets, so this is hardening
rather than a live bug, but it is the one place in the interop where a bound is
checked on one side only. (`SearchFS.parseBatch` does not have this problem: it
validates `nameDataOffset` against two exact expected values, `28` or `40`.)

**Fix applied:** added the lower bound.

### M4. ~~Hardened Runtime is off~~ — withdrawn, it was already on

I initially reported this as a finding. It is wrong, and the error was mine: my
first grep over `project.pbxproj` passed through `uniq -f2`, which discarded the
`ENABLE_HARDENED_RUNTIME` lines before I saw them. Re-audited per configuration:

| Target | Config | Hardened Runtime |
|---|---|---|
| OpenDisk (direct) | Debug | **YES** |
| OpenDisk (direct) | Release | **YES** |
| OpenDisk MAS | Debug | no |
| OpenDisk MAS | Release | no |

The build you will actually run — the non-sandboxed one holding Full Disk
Access — already has Hardened Runtime enabled, so it already rejects
`DYLD_INSERT_LIBRARIES` and task-port attach from unsigned code. The MAS target
does not have it, which is correct: Hardened Runtime is a Developer ID
distribution requirement, not an App Store one, and App Store builds get their
protection from the sandbox instead.

**No change made.** Recording the withdrawal rather than deleting it, because a
review that quietly drops a claim is harder to trust than one that corrects it.

### M5. Sandbox detection relies on an environment variable

**File:** `OpenDisk/Services/ScanAccess.swift:18-19`

```swift
nonisolated static let isSandboxed =
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
```

Environment variables are attacker-controlled if the attacker controls the
launch. Spoofing it *on* in the direct build makes the app demand grants it does
not need; spoofing it *off* in the MAS build makes `beginAccess` return `true`
unconditionally (`:111`) and every scan silently fail. Neither is a privilege
escalation — the kernel enforces the sandbox regardless of what this flag says —
so this is a correctness/robustness issue, not a boundary bypass.

**Fix applied:** three signals, most trustworthy first —
(1) the `com.apple.security.app-sandbox` entitlement read from our own code
signature via `SecCodeCopySelf` + `SecCodeCopySigningInformation`;
(2) whether `NSHomeDirectory()` has been redirected into
`~/Library/Containers/…`, which reflects what the kernel did to the process
rather than what its launcher claimed;
(3) the environment variable, only if neither of the first two can answer.

Signal (1) returns "don't know" rather than "not sandboxed" for a build with no
entitlements in its signature — an unsigned or ad-hoc local build — which is why
(2) exists. Verified: `ScanAccess.isSandboxed` is `false` in the non-sandboxed
test runner (new test in `ScanAccessTests`).

---

## 🟢 Low / notes

- **L1. `path(of:)` silently truncates.** `FileTree.swift:208-219` bounds its
  parent walk (good) but on hitting the bound returns the partial path joined to
  the root prefix — a *different, real* path. That value flows into
  `CollectedFile.path` and thence to deletion. Only reachable with a corrupted
  cache (see M1), but "return a plausible wrong path" is the wrong failure mode
  for a delete pipeline. **Fixed:** returns `nil`; callers skip the row.
- **L2. `isInApplicationsFolder` over-matches.** `MoveToApplications.swift:56-61`
  uses the regex `(^|/)Applications(/|$)`, so `~/Downloads/Applications/` counts
  as installed. Moot now that the file is removed with Sparkle.
- **L3. `getattrlistbulk` errors are swallowed.** `BulkDirectoryReader.swift:109`
  treats `count <= 0` as end-of-directory without inspecting `errno`, so a
  genuine mid-read failure silently yields a partial listing that looks complete.
  Left as-is — the comment documents the choice and it is the safer direction
  for a scanner (under-report rather than fail).
- **L4. `Data(contentsOf:.mappedIfSafe)`** in `ScanCache.load:26` will `SIGBUS`
  if the file is truncated by another process while mapped. Narrow window,
  local-only, not fixed.
- **L5. Cleanable-cache entries that will partially fail:**
  `/Library/Caches` (needs admin) and `~/go/pkg/mod/cache` (Go sets the module
  cache read-only, which is why `go clean -modcache` exists). Both will produce
  partial deletions and misleading totals. Kept, but the failure list in the tray
  now shows why.
- **L6. `~/.Trash` in the cleanable catalogue.** Defensible, but with permanent
  deletion it destroyed the user's last recovery path. Less alarming now that the
  default is trashing; kept.

## ✅ What the code does well

Worth saying plainly, because it shaped how much of this review is hardening
rather than repair:

- **No network I/O, no credentials, no secrets, no telemetry.** The entire
  `security` skill checklist for Keychain, biometrics, ATS and certificate
  pinning is not applicable — there is nothing to protect and nothing to leak.
  The only outbound connection in the whole project was Sparkle's.
- **Symlinks are never followed.** `open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)`
  (`BulkDirectoryReader.swift:76`) is the right call, and the skeleton reader
  filters symlinks to match (`DiskAnalyzer.swift:565`). No scan-time traversal
  loop is possible.
- **Volume boundaries are enforced twice** — by `st_dev` allowlist on the opened
  descriptor *and* by per-entry `ATTR_DIR_MOUNTSTATUS` — with a documented
  explanation of why either alone is insufficient on APFS volume groups.
- **Cache validation is genuinely careful**: format version, root path, and the
  volume's device ID must all match, so a reformatted disk at the same mount
  point cannot resurrect a stale tree (`ScanCache.swift:38-56`).
- **Buffer parsing is bounds-checked** in all three raw-pointer parsers I read in
  full — `BulkDirectoryReader.parseRecord`, `CatalogSearch.parseBatch` and
  `SearchIndex.sweep` — with only the one signed-offset gap in M3. The `searchfs`
  parser derives record shape from the name offset and refuses anything
  unexpected rather than guessing; `sweep`'s `memmem` walk is correctly bounded
  by the offsets array, and its "a match can never straddle two names" argument
  holds because names cannot contain NUL and a folded query cannot either.
- **Concurrency is disciplined**: `Mutex`/`Atomic` from `Synchronization`, blocking
  syscalls kept off the cooperative pool by design, and an exactly-once
  continuation latch in `FSEventsChangeJournal` that correctly handles the
  HistoryDone-vs-timeout-vs-cancellation race.

## Residual risk after the fixes

What is deliberately still true of this fork, so you are not inferring it from
scattered notes:

- **`freedBytes` is still a scan-time figure**, not a measurement of what was
  actually reclaimed. It is now only labelled "freed" on the permanent-delete
  path, but it will still be wrong for a stale scan, for hard-linked content, and
  for a partially failed directory removal (H1).
- **`/Library/Caches` and `~/go/pkg/mod/cache` will partially fail** — the first
  needs admin rights, the second is deliberately made read-only by Go. You will
  see failures in the tray rather than a clean result (L5).
- **`getattrlistbulk` errors are still swallowed** (L3), so a directory that
  fails mid-read is reported as smaller than it is rather than as an error. This
  is the safer direction for a scanner and is left alone.
- **`ScanCache` still memory-maps** its cache file, so a file truncated by
  another process while mapped would `SIGBUS` (L4). Local-only, narrow window.
- **`~/.Trash` remains in the cleanable-cache catalogue.** Much less alarming now
  that deletion defaults to trashing, but worth knowing it is there (L6).
- **The scan cache is still attacker-writable** at
  `~/Library/Caches/ideals.OpenDisk/ScanCache/`. The hang is fixed and paths that
  can't be derived are dropped, but a process already running as you could still
  make the app *display* misleading rows. Defending against that properly would
  mean authenticating the cache file, which is disproportionate for a machine
  where the attacker already has your privileges.

## What I did not verify

- **The Mac App Store build's sandboxed behaviour.** `isSandboxed` returning
  `true` via the entitlement query cannot be exercised here — a sandboxed build
  needs a provisioned MAS signing identity. Only the `false` path is tested. The
  MAS target does compile and link in Release.
- **A live Finder drag against the drop target** (H4). The finding is reasoned
  from the declared UTI, and the fix is verified structurally instead: the
  exported type is present in the built `Info.plist`, `UTType.openDiskCollectedFiles`
  resolves without trapping, and `UTType.json` does not conform to it.
- **Actual deletion of anything real.** All deletion testing used temporary
  directories. I did not run the app against your disks.

## 🔧 Bug: the test suite does not compile

Not a security issue, but it blocks verification of everything above.

```
OpenDiskTests/CatalogTreeBuilderTests.swift:3:18: error: compiling for macOS 15.5,
but module 'OpenDisk' has a minimum deployment target of macOS 26.0
```

Both test targets are pinned to `MACOSX_DEPLOYMENT_TARGET = 15.5` while the app
module requires 26.0, so `xcodebuild test` fails at build time and **every test
in the repository is dead upstream**. Fixed by raising the test targets to 26.0.
No test logic was changed.

## 🔄 Upstream ports (Sep 2026)

Selective ports from upstream `137137137/OpenDisk` (commits `3ac9188`,
`f08d30e`, `999fae2`, `ddc3646`, `8854e7d`, `d8728af`, `d628684`), adapted
file by file — never merged, so none of the fixes above were regressed.
Deliberately *not* ported: Sparkle/`SoftwareUpdater`, `MoveToApplications`,
the Check-for-Updates UI (C1), the `ProtectedPaths` simplification (C2),
`Collector` deletion-path changes (H1), the `LICENSE` attribution removal, and
the macOS 15 deployment-target lowering.

Security-relevant consequences of what *was* ported:

- **Cache/tree format changed** (`ScanCache` v1→v2, `FileTree` magic
  `"DMT2"`→`"DMT3"`): trees now persist per-inode hard-link records. Old
  caches are rejected by both version checks and the root is rescanned — a
  stale file can never be misparsed as the new layout.
- **Hard-link records are untrusted input.** The deserializer validates every
  record (ID in range, non-root, non-directory) and `normalizeHardLinks()`
  drops records for unreachable nodes, so a tampered cache can at worst force
  a full-scan fallback, never misattribute bytes to a wrong node (whose size
  feeds the Collector).
- **Catalog/`searchfs` code is deleted** (`CatalogScanner.swift`,
  `SearchFS.swift`), not merely unbuilt — one less private-syscall surface,
  and no dead scanner for a future change to accidentally re-enable.
- Hard-link *totals* are now counted exactly once across re-reads (previously
  double-counted); `freedBytes` remains a scan-time figure (residual risk,
  first bullet above).

---

## 🔄 Upstream ports (Oct 2026)

Upstream moved from `70a67e3` to `f7551cf` (v1.2.2 → v1.2.8, 17 commits). All
17 were read. None reintroduces anything the fixes above removed: there is no
new network code, no new `Process` use outside `MoveToApplications` (which
this fork does not have), and no change to `ProtectedPaths` or the deletion
path. Upstream still ships Sparkle and still compares paths as raw strings.

Ported, commit by commit and adapted — never merged:

| Upstream | What | Adaptation |
|---|---|---|
| `228e962` | Full Disk Access probe requires every location to be readable | none |
| `e9a1158`, `43e4967` | AppKit drag source; drags reach other apps as files; items can be dragged out of the Collector | private type kept; **copy-only outside the app**; see below |
| `ab1644a`, `628c2e5` | "Available" includes purgeable space, polled every 2s | none |
| `d987b27` | Incremental updates reuse the cache more often | kept synchronous and off the cooperative pool; L1, M2 preserved |
| `59a83ec` | Enclosing Folder button (⌘↑) | breadcrumb half skipped (pre-macOS 26 workaround) |
| `ccc37cd`, `80e91c7` | Free-space wedge on the chart, with a setting | none |
| `f7551cf` | Configurable keyboard shortcuts | sheets and alerts keep their keys |

Not ported:

- `4b1c06b`, `e1f10eb` — `MoveToApplications` (C1). The second also adds an
  AppTranslocation guard to the FDA prompt, which is only meaningful alongside
  that file's relaunch.
- `c1bf746`, `a1b0685` — a rewrite of the traversal worker pool onto
  continuations, done to quiet Swift 6 sendability diagnostics the fork does
  not have. `a1b0685` also takes `IncrementalUpdater.apply` off the offload
  queue, putting its blocking directory reads on the cooperative pool — the
  exact thing `TraversalScanner`'s header comment warns against.
- `6e6ac7d` — added, then removed again by `43e4967`.
- `1ebeea4`, `efbdec5`, `f94fd40` — version bumps.

Security-relevant consequences of what *was* ported:

- **H4 is now enforced by in-process state**, not by a type name. See the note
  added under H4.
- **A drag out of the app can copy a file but never move it.** Upstream offers
  `.move` and `.generic` to other apps, so dragging a row onto a Finder window
  on the same volume *moves* the file, and dragging it onto the Dock's Trash
  bins it — with no confirmation and no `ProtectedPaths` check. That is a
  second deletion path beside the Collector, bypassing C2 and H1 entirely.
  This fork offers `.copy` alone (`FileDragSource.operationMask(for:)`, pinned
  by a test). Finder copies; the Trash refuses the drop.
- **Items dragged out of the Collector carry no file URL.** That gesture can
  only un-collect; nothing on disk can be copied, moved or removed by it.
- **Keyboard shortcuts cannot delete.** `addToCollector` (⌘⌫ by default) calls
  the same `collect()` as a drop, so it passes the same `ProtectedPaths`
  filter and still ends at the Collector's confirmation. Matching uses a local
  event monitor; nothing is registered system-wide and no new permission is
  requested.
- **Cache header v2→v3** adds a capture time and a measured scan duration.
  Both are doubles read from disk and both feed arithmetic, so a non-finite or
  negative value makes the cache unusable rather than reaching a timeout or a
  date comparison. v2 files are rejected and the root rescanned once.
- **Hard-link acceptance is looser, on purpose.** An incremental update now
  accepts a hard link the cache never recorded if the *inode* was born after
  the cached scan began. The decision rests on `st_birthtime`, which a local
  process can set; the worst outcome of a wrong answer is a mis-sized chart
  (bytes counted twice, or a needless full scan). These values do not reach
  the deletion path, and callers that pass no capture time get the old strict
  rule.
- **Large files are `lstat`-ed after an incremental update**, by a path built
  from the tree. `path(of:)` returning nil skips the node (L1): a truncated
  path is a different real file, whose size would otherwise be written onto
  the wrong node.

Not verified by hand: the drag gestures themselves. The pasteboard contents,
operation mask and Collector state changes are covered by tests; a real mouse
drag — row to Collector, row to Finder, item out of the Collector — is not
something the test suite can perform.
