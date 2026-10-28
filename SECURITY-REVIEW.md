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

**Fix applied:** a custom exported UTI, `ideals.OpenDisk.collected-files`, declared
in `Info.plist` and conforming to `public.json`. The drag payload now uses that
type, so a plain `.json` file no longer matches the drop target. In-app drags are
unaffected.

**Superseded, Oct 2026 — now stronger than the fix above.** The private type
only ever kept *accidental* payloads out: a type identifier is a string, and a
hostile app can write any string to the drag pasteboard. With the drag rewrite
ported from upstream (`e9a1158`, `43e4967`) the drop target no longer decodes
a payload at all. `InAppFileDropTarget` (`InAppFileDropDelegate` until the
port of upstream `9f521fe`, which made it an AppKit view to fix stuck hover
state; the guard is unchanged) accepts a drop only while
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

Upstream moved from `70a67e3` to `f7551cf` (v1.2.2 → v1.2.8, 18 commits). All
18 were read. None reintroduces anything the fixes above removed: there is no
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

---

## 🔄 Upstream ports (Oct 2026, second review)

Upstream moved from `f7551cf` to `0d296b5` (v1.2.8 → v1.4.3, then a README
badge): 41 commits plus 6 merges, all read. As before, nothing reintroduces
what the fixes above removed — no new network code, no `Process`, no change
to `ProtectedPaths` — but three commits would have weakened fixes the fork
already had (see "Not ported"). Upstream still ships Sparkle; v1.4.2 and
v1.4.3 only trim its bundle.

Ported, adapted by hand or with `cherry-pick -n` — never merged:

| Upstream | What | Adaptation |
|---|---|---|
| `9f521fe` | Collector drop target becomes an AppKit view (fixes stuck hover and pop-up after a quick drop) | renamed `InAppFileDropTarget`; H4 guard unchanged |
| `c59457a` | Refresh rescans from the scan root | none |
| `01f7a8e`, `5bf9e47` | Back goes up one level; Forward; mouse side buttons and swipes; sizes in the breadcrumb bar | comments kept; breadcrumbs stay buttons (the `368eef2` pre-macOS 26 workaround is not taken) |
| `6b60c02` | Cache names gathered into one buffer before writing | none; output byte-identical |
| `a5bd938` | Device list refreshes on volume mount, unmount and rename | none |
| `628985d` | Chart centre follows dark mode; layout only rebuilt when its square changes | none |
| `c1ddf4d` | Chart skips sorting children too small to draw | fork's tie-break order kept |

Not ported:

- `454f898` — upstream's own "Move to Trash" option. Weaker than H1 in three
  ways: permanent delete stays the primary button (so Trash stops being the
  default), there is no `ProtectedPaths` re-check immediately before each
  removal, and bytes moved to the Trash are reported to the host as freed.
- `904f180`, `72f0ecb` — in-memory compaction after incremental rescans.
  Duplicates M2: this fork compacts on every save, and each rescan starts
  from that compacted file, so at most one rescan's garbage is ever held.
  Its test exercises repeated in-memory updates, which the app never does.
- `78f5f92` — shows the stale cached tree while a full rescan runs. It loads
  the cache with `Task.detached`, i.e. a large blocking file read on Swift's
  cooperative thread pool, which `ScanEngine` keeps free by routing blocking
  work through `offload`. Portable only with that changed; deferred with
  the redesign it belongs to. (Ported later with that change; see
  "Upstream ports (Oct 2026, redesign)" below.)
- `3a6951d` and its follow-ups (`f8365ae`, `e1a40b4`, `dc6e1c8`, `d13954d`,
  `ba6672d`, `fb76404`, `ab868c6`, `3a09ac2`, `d7faff5`, `90c12c6`,
  `59d87ab`, `d2958b7`, `71d09de`, `4574ad8`) — the v1.4 window redesign
  (sidebar, Finder-style list, text size). Reviewed and clean on security:
  no new deletion or drag path, drags still leave through `FileDragSource`
  (copy-only, invariant 6), `ProtectedPaths` is only read, and the one new
  action is Reveal in Finder. Deferred as a product decision: every commit
  conflicts, `ab868c6` changes an existing test's expected value
  (`"1:05"` → `"1 min 5 sec"`), `d7faff5` starts a whole-disk scan at every
  launch, and `fb76404` re-reads the device list every 3 seconds. (Ported
  later, with those three points settled; see "Upstream ports (Oct 2026,
  redesign)" below.)
- `868ff2c`, `815fef1`, `13501d4`, `98bce73`, `368eef2`, `0d296b5` — macOS
  14/15 and Xcode 16 support. The fork is pinned to macOS 26; `868ff2c` also
  swaps `Synchronization` for a hand-rolled lock and edits two existing tests.
- `9c95eeb`, `9a90f25` — Sparkle bundle trimming (C1: no Sparkle here).
- `a3c71df` — a README star-history chart loaded from a third-party site.
- `e421ee4`, `6e1769d`, `709dd07`, `387e00c`, `80e4974` — version bumps.

Security-relevant consequences of what *was* ported:

- **H4 holds unchanged.** The drop target refuses any drag unless
  `FileDragSource.shared.activeFiles` is set and takes the files from there;
  `registerForDraggedTypes` only decides which drags are offered to the view
  and reads no data. The view returns nil from `hitTest`, so it never
  intercepts clicks or hovers.
- **The navigation gestures are local.** `NSEvent.addLocalMonitorForEvents`
  sees only events already addressed to this app, and the handler ignores
  any window but the scan window. No permission is requested. ⌘[ moved
  from Unmount (now ⌘E) to Back.
- **Nothing ported touches deletion, `ProtectedPaths` or the drag operation
  mask.** No `project.pbxproj` hunk was taken from upstream; the version
  bump was written by hand.

Not verified by hand: the gestures and the hover fix themselves (mouse side
buttons, swipes, a quick drop followed by a return to the list), and the
chart in dark mode. The test suite (115 tests, 10 new for navigation) covers
the navigation model and every pre-existing behaviour, not live input.

---

## 🔄 Upstream ports (Oct 2026, redesign)

The v1.4 window redesign and `78f5f92`, deferred in the second review above,
were ported on 28 October 2026 with three adjustments the user chose: the
launch-time scan (`d7faff5`) is an opt-in setting, off by default; the
3-second device-list polling (`fb76404`) is left out; and the one edit to an
existing test (`FormattersTests`, `"1:05"` → `"1 min 5 sec"`) was approved.

Ported by hand from upstream's end state rather than commit by commit. The
intermediate states add things that later commits in the same series remove
again (`SelectionSummary.swift`, `StorageOverview.swift`,
`DiskAnalyzer.fileCount`), so replaying them would have meant writing code
only to delete it. The table maps each upstream commit to where it landed.
Upstream's own commit messages were not reused (several carry AI
`Co-Authored-By` trailers), and no `project.pbxproj` hunk was taken.

| Fork | Upstream | What | Adaptation |
|---|---|---|---|
| `b636192` | `ab868c6` (non-UI) | Capacities under 1 GB in MB; durations as "1 min 5 sec"; equal-sized names sort as Finder does | raw comparison as a final tie-break, so the order stays total |
| `9fb0baa` | `d13954d` (non-UI) | "n of total" steps while journal changes are spliced in; counters restart before a full traversal | `IncrementalUpdater.apply` stays inside `offload` |
| `f55c446` | `e1a40b4`, `59d87ab` | Same-location rescans keep the old rows and chart up; partial results hide noise; chart built off the main actor | a waiting chart rebuild is dropped when the chart is set outright |
| `a9d7240` | `78f5f92` | A cache over 6 hours old is shown during a full rescan instead of replayed | loaded through `offload`, not `Task.detached`; the untouched cached tree replaces a half-spliced one. As upstream, if that old cache fails to load, the scan shows only the skeleton until it finishes |
| `85e2ba8` | `3a6951d`, `d2958b7`, `e1a40b4`, `f8365ae`, `dc6e1c8`, `fb76404`, `ab868c6` | Sidebar of disks and folders replaces the disk picker and Unmount | guided placeholder kept; device list refreshes on this app's activation, not on a timer |
| `d104908` | `3a6951d`, `71d09de`, `4574ad8`, `59d87ab`, `dc6e1c8` (`90c12c6` superseded by `71d09de`) | Finder-style list (Name, Size, bar, Kind); click selects, double-click opens; text size ⌘+ ⌘= ⌘− ⌘0 | macOS 26 path only; search rows' first menu item says "Open" |
| `fda6fcf` | `3a6951d`, `3a09ac2`, `d2958b7`, `fb76404`, `f8365ae`, `ba6672d`, `ab868c6`, `d13954d` | Hideable inspector (chart and Collector); path bar above the list; status bar trimmed; Collector restyle; chart resizes smoothly | inspector reopens when anything is collected; Delete keeps "Move to Trash" label; path bar still scrolls; status bar drops upstream's always-empty leading slot and keeps 5 pt of vertical padding |
| `84b34c5` | `d7faff5` | Scan a location at launch | **opt-in, off by default**; read once per window; skipped when hosting tests |

Not ported:

- `fb76404`'s 3-second refresh loop, and its observer of *every* app's
  activation (`NSWorkspace.didActivateApplicationNotification`, which tells
  the app what else the user switches to). The device list refreshes on mount,
  unmount and rename, as before, and when OpenDisk itself becomes active.
- `FileTree.descendantFileCount` and `DiskAnalyzer.fileCount` (`e1a40b4`),
  with their `FileTreeTests` test. The only caller was removed again in
  `d2958b7`, and the new walk follows sibling chains with no bound, the
  hang that invariant 7 exists to prevent (M1).
- `SelectionSummary.swift` (`3a6951d`, removed by `d2958b7`) and
  `StorageOverview.swift` (`3a09ac2`, removed by `d7faff5`).
- Every `#if compiler(>=6.2)` / pre-macOS 26 branch (the pinned-section list
  header, the capsule Delete button).
- `ab868c6`'s collapsing breadcrumb variants, which build on `368eef2`'s
  `ViewThatFits` layout (not ported). The fork's path bar scrolls sideways.
- `FileKind.isPackage`, defined upstream but never called.
- Upstream's analysis view still refreshes on
  `FileDragSource.filesMovedNotification` (from before v1.3.1). That only
  matters when a drag out of the app *moves* a file, which this fork forbids
  (invariant 6), so there is nothing to react to.

Security-relevant consequences of what *was* ported:

- **No new deletion path.** The new actions are: sidebar "Show in Finder"
  (reveal only); sidebar "Remove from Sidebar" (forgets a saved path, or in the
  App Store build a bookmark: `removeGrant` ends its security-scoped access,
  and the analysis view's own `endAccess` is then a no-op; nothing on disk is
  touched); "Scan Folder…" (now a `fileImporter`, website build only; adds a
  path); the row menu's "Open" / "Quick Look" and double-click (navigate or
  preview); a clickable current breadcrumb (navigation, leaves search); the
  Inspector toggle (layout); the text-size commands (one preference). The
  restyled Collector button still only opens the existing confirmation, which
  runs `deleteAll` with the per-item `ProtectedPaths` re-check and Trash by
  default (H1).
- **No new drag path.** Sidebar rows cannot be dragged. List rows and chart
  rings still go through `.fileDrag` and `FileDragSource` (copy-only outside
  the app, invariant 6), and `InAppFileDropTarget` (H4) still sits over the
  inspector pane alone. `FileDrag.swift`, `Collector.swift` and
  `ProtectedPaths.swift` are unchanged by this port.
- **Hiding the inspector hides the Collector.** Upstream lets ⌘⌫ or the row
  menu collect into a tray that is off screen; the rows just vanish from the
  list. The fork reopens the inspector whenever the Collector grows, so
  anything queued for deletion is always visible beside its Delete button.
- **Rows can be older than before.** A same-location rescan keeps the
  previous rows up until new data arrives, including rows for files just
  deleted, and a cache over 6 hours old stays on screen for a whole full scan
  (previously only until the replay or traversal replaced it). Those rows can
  be collected. The consequences are bounded by what already exists: the
  confirmation, the `ProtectedPaths` re-check before each removal, Trash by
  default, and a vanished path failing and being reported. Sizes shown in the
  Collector remain scan-time figures (residual risk, first bullet).
- **No blocking I/O moved onto the cooperative pool.** The stale cache read
  goes through `offload`. The chart build moved to a detached task, but it is
  computation on an in-memory tree, with no file access.
- **Launch reads nothing new by default.** With the setting off (the
  default) launch lists devices, as before, and scans nothing; the last
  location is not recorded. With it on, launch never shows an access panel,
  never opens an external volume, and never runs inside the test host.
- **New preferences**, all plain UserDefaults values shared with the test
  host: `sidebar_folders` (website build: paths of added folders),
  `inspector_visible`, `list_text_size_level`, `scan_at_launch`, and
  `last_location` (only while `scan_at_launch` is on). No new network code,
  no `Process`, no new entitlement or permission.
- **Shortcuts.** ⌘E is free again (Unmount went with the disk picker). New:
  ⌥⌘I (inspector), ⌘+ / ⌘= / ⌘− / ⌘0 (text size). The configurable list
  shortcuts are unchanged.
- **The free-space wedge** is now drawn only when the scan root is a volume;
  a scanned folder used to show the whole disk's free space as part of itself.

Tests: 127 (118 before). New: upstream's `capacities` and two `DiskAnalyzer`
tests (keep results while rescanning; partial-result noise), plus the fork's
Finder-order test, a `ScanMetrics` step-counter test and four
`LaunchLocation` tests (the default is off; last internal location, else the
startup disk; never an external volume; never a location needing a prompt).
Each failed against the pre-port code: the two `DiskAnalyzer` tests, the
Finder-order test and the duration cases by assertion, `capacities` by
assertion against a stub `formatCapacity` (so the file compiled), and the
`ScanMetrics` and `LaunchLocation` tests by not compiling against the old
API. The one edited test is the approved
`FormattersTests` duration case. `78f5f92` has no test: exercising it end to
end means writing into the app's real cache directory, whose pruning could
evict the user's own caches.

Not verified by hand: the whole redesigned window. In particular a row drag
to the Collector alongside the new double-click; the sidebar collapsing when
a scan finishes; hiding the inspector and collecting with ⌘⌫; text size; the
launch setting both ways; the sandboxed build's padlocks and grant panel from
the sidebar; and the stale-cache display on a rescan after more than six
hours.
