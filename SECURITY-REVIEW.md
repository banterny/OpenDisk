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
| Deletion safety | ❌ | 1 critical, 3 high |
| Filesystem interop (memory safety) | ⚠️ | 1 medium, 1 low |
| Cache / persistence | ⚠️ | 2 medium |
| Build & signing | ⚠️ | 2 medium |
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

**Reachability:** `ScanEngine.resolveDataVolumeAlias` (`ScanEngine.swift:233-237`)
deliberately constructs `"/System/Volumes/Data" + path` when a path is not
visible at its normal location, so this prefix is a first-class citizen in the
engine, not a hypothetical. Any path reaching the Collector with that prefix is
unguarded.

**Fix applied:** `normalized()` now canonicalises with `resolvingSymlinksInPath`
(which *does* collapse firmlinks — verified) and explicitly strips a leading
`/System/Volumes/Data`, with the raw path also checked so a non-existent path
that resolves to nothing is still caught. New tests in
`OpenDiskTests/ProtectedPathsTests.swift` cover the firmlink, symlink and
`/private` forms. No existing test was modified.

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

**Fix applied:** deletion now defaults to `trashItem(at:resultingItemURL:)`, with
a Settings toggle for permanent deletion (off by default). When trashing, the
tray says "Moved to Trash" rather than claiming space was freed, because it
wasn't until the Trash is emptied. `deleteAll()` also re-checks `ProtectedPaths`
immediately before each removal, closing the window between collect-time and
delete-time.

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

### M4. Hardened Runtime is off

**File:** `OpenDisk.xcodeproj/project.pbxproj` — no `ENABLE_HARDENED_RUNTIME` in any configuration.

Without it the process permits unsigned code injection (`DYLD_INSERT_LIBRARIES`,
task-port attach). In a **non-sandboxed app holding Full Disk Access** that is
the difference between "a bug lets something read your files" and "any local
process can borrow this app's FDA". It also makes notarisation impossible, which
matters if you ever want to run the build on a second Mac without
right-click-Open.

Its severity is coupled to C1: Sparkle is the realistic vector that would want
to inject into the app, and with Sparkle gone the exposure drops considerably.
Still worth turning on.

**Fix applied:** `ENABLE_HARDENED_RUNTIME = YES` on both app targets.

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

**Fix applied:** replaced with a code-signing query
(`SecCodeCopySelfSigningInformation` → `com.apple.security.app-sandbox`
entitlement), falling back to the environment variable if that fails.

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
- **Buffer parsing is bounds-checked throughout**, with only the one signed-offset
  gap in M3. The `searchfs` record parser derives record shape from the name
  offset and refuses anything unexpected rather than guessing.
- **Concurrency is disciplined**: `Mutex`/`Atomic` from `Synchronization`, blocking
  syscalls kept off the cooperative pool by design, and an exactly-once
  continuation latch in `FSEventsChangeJournal` that correctly handles the
  HistoryDone-vs-timeout-vs-cancellation race.

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
