# OpenDisk — working notes

Security-reviewed fork of [137137137/OpenDisk](https://github.com/137137137/OpenDisk).
Read [SECURITY-REVIEW.md](SECURITY-REVIEW.md) before changing anything in the
deletion, path-guard, or update paths — it explains *why* several things are
written the way they are, and the reasoning is not obvious from the code alone.

## Commands

```bash
# Tests (127). Run these before and after any change.
xcodebuild test -scheme OpenDisk -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenDiskTests

# Build both distribution targets
xcodebuild -scheme OpenDisk       -destination 'platform=macOS' -configuration Release CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme 'OpenDisk MAS' -destination 'platform=macOS' -configuration Release CODE_SIGNING_ALLOWED=NO build
```

Signing: the project carries no Team ID. Create `Local.xcconfig` (gitignored)
as described in [`Signing.xcconfig`](Signing.xcconfig) to sign locally; without
it, use `CODE_SIGNING_ALLOWED=NO`. There is no lint or format step.

Requires macOS 26 (Tahoe) and Xcode 26+. Both app targets and both test targets
are pinned to `MACOSX_DEPLOYMENT_TARGET = 26.0` — they must stay in step. When
they drifted upstream (tests at 15.5, app at 26.0) the entire suite silently
failed to compile, so every test in the repo was dead.

## Invariants — do not regress these

Each one is a fixed finding. Reintroducing any of them re-opens a real hole.

1. **No auto-updater, and no `Process` spawning at startup.** Upstream bundled
   Sparkle pointed at a third party's server and key, so a reviewed build
   replaced itself with an unreviewed one. `MoveToApplications.swift` went with
   it; it shelled out to `xattr` to strip its own quarantine, and it was
   observed *self-installing a test build into /Applications during an
   automated test run*. This fork updates by rebuilding from source. (C1)
2. **`ProtectedPaths` must canonicalise, never compare raw strings.** The same
   directory has several names on macOS. `/System/Volumes/Data$HOME` and
   `$HOME` are the same inode; upstream's guard knew only the second, so every
   protected location was reachable by prefixing `/System/Volumes/Data`. (C2)
3. **The "is this on a system volume?" rule applies to the *resolved* path
   only.** Applying it to the literal path refuses every deletion under a
   Data-volume scan root — which is exactly what the sandboxed build's open
   panel returns for "Macintosh HD — Data". I made this mistake once; the test
   `Data-prefixed ordinary files are still deletable` exists to catch it.
4. **Deletion defaults to the Trash**, and `deleteAll` re-checks
   `ProtectedPaths` immediately before each removal, not only at collect time.
   Note `deleteAll(using:)`'s *parameter* default is `.permanent` so the
   pre-existing tests stay hermetic; `CollectorBar` passes the mode explicitly. (H1)
5. **The Collector's drop target never reads the pasteboard.** Dropped files
   become deletion candidates, so `InAppFileDropTarget` (an AppKit view in
   `FileDrag.swift`) accepts a drop only while
   `FileDragSource.shared.activeFiles` is set — a drag begun in this
   process — and takes the files from there. Do not reintroduce
   `.dropDestination(for:)` or any decoding of a dragged payload. The private
   type `ideals.OpenDisk.collected-files` (never `public.json`) remains as
   the marker for drags with no file URL; it is exported in
   `OpenDisk-Info.plist`, and `UTType(exportedAs:)` traps if that declaration
   goes missing. (H4)
6. **A drag out of the app is copy-only.** `FileDragSource.operationMask`
   must not offer `.move` or `.generic` outside the application: either lets
   Finder move the file, or the Dock's Trash bin it, with no confirmation and
   no `ProtectedPaths` check. Upstream offers both. (H1, C2)
7. **Every sibling-chain walk in `FileTree` is bounded.** The `visited` bitmap
   bounds the *stack*, not the sibling chain; an unbounded walk hangs forever
   on a cycle from a corrupted cache. (M1)
8. **`FileTree.path(of:)` returns `String?`.** A truncated path is a
   *different, real* path, and these values flow into deletion. Callers skip
   rows they cannot resolve. (L1)
9. **Trees are compacted before being written to `ScanCache`**, or incremental
   rescans persist their own orphans and the cache grows without bound. (M2)

## Conventions

- **Never edit an existing test to make a change pass.** Every fix in this fork
  added tests; none modified one. Each new test was confirmed to *fail* against
  the unfixed code before being accepted — a test that passes both ways is
  proving nothing.
- The codebase is unusually heavily commented and the comments carry real
  reasoning (benchmark numbers, why an approach was rejected). Match that
  density; explain *why*, not *what*.
- Findings are referenced by ID (`C1`, `H4`, `M2`…) in comments and commit
  messages, pointing back at `SECURITY-REVIEW.md`.

## Environment gotchas

- `timeout` is **not** available on macOS. Use a background run plus a polling
  loop, or `gtimeout` from coreutils.
- A test run killed mid-flight leaves an orphaned test-host process holding the
  build lock; the next `xcodebuild` then appears to hang. Clear it with
  `pkill -f "xcodebuild test"` and `pkill -f "DerivedData/OpenDisk-.*MacOS/OpenDisk"`.
- Piping `xcodebuild` through `grep` buffers everything until the run ends —
  redirect to a file if you want to watch progress.
- Swift Testing suites report via `✔ Test run with N tests`; the legacy
  `Executed 0 tests` line is XCTest's counter and does not mean nothing ran.
- The test host is the app itself. Its startup "Full Disk Access Required"
  alert runs a modal loop that blocks the main actor, so it is skipped when
  `FullDiskAccess.isHostingTests()` is true (Xcode sets
  `XCTestConfigurationFilePath`). If a run ever sits at 0% CPU after
  `Executed 0 tests`, look for that alert first. Never tick its "don't ask
  again": the preference is shared with the installed app.
- Every preference is shared that way, including the redesign's
  (`sidebar_folders`, `inspector_visible`, `list_text_size_level`,
  `scan_at_launch`, `last_location`). Anything that acts on a preference at
  launch must also check `FullDiskAccess.isHostingTests()`; the optional scan
  at launch does, or turning it on in the installed app would start a
  whole-disk scan on every test run.
- Run `xcodebuild` outside Claude Code's sandbox. Inside it, a test run was
  seen to log "Operation not permitted" on a CoreSimulator log file under
  `~/Library/Logs` and then stop with "Testing cancelled because the build
  failed". The likely cause is that it cannot write its build folders under
  `~/Library` (DerivedData), but the actual build error was not read, so
  that is not confirmed.

## Syncing from upstream

```bash
git fetch upstream && git diff HEAD upstream/main   # read this before merging
git merge upstream/main
```

Read the diff first — that is the whole point of the fork, since there is no
updater to do it for you. Watch in particular for anything reintroducing
Sparkle, `MoveToApplications`, `removeItem` as the deletion default, string
comparison in `ProtectedPaths`, `.move` in the drag operation mask, or `async`
on the scanner's blocking calls. Also for `Task.detached` around blocking
file I/O (upstream reads the scan cache that way; the fork uses `offload`),
polling timers (upstream re-reads the device list every 3 seconds), and
anything that starts a scan at launch unasked (here it is an opt-in setting,
off by default). Re-run the tests after any merge.

In practice a merge is not workable: upstream stripped its comments and the
fork kept them, so nearly every hunk conflicts. What has worked is
`git cherry-pick -n <commit>` one commit at a time, restoring
`OpenDisk.xcodeproj` and `OpenDisk-Info.plist` from `HEAD` after each, then
reading every hunk. Last reviewed upstream commit: `0d296b5` (v1.4.3 plus a
README tweak). Everything up to there that the fork wants is ported,
including the v1.4 window redesign; the "Upstream ports" sections of
`SECURITY-REVIEW.md` list what was left out and why.

For a large upstream series, porting from the end state worked better than
replaying commits: the redesign's commits add files and functions that later
commits in the same series delete again. Map each upstream commit to a fork
commit in the review notes so the history stays traceable.

Use `git cherry-pick -n` (or hand-port) and write your own commit message:
several upstream commits carry `Co-Authored-By` trailers for an AI tool,
which must not reach this repository.

After a port, update what the About box says, in `project.pbxproj` for both
app targets: `MARKETING_VERSION` tracks the upstream release the fork has been
reviewed up to (it is *not* a claim to be that release — see the "not ported"
lists in `SECURITY-REVIEW.md`), `CURRENT_PROJECT_VERSION` is the fork's own
build counter, and `INFOPLIST_KEY_NSHumanReadableCopyright` carries the fork
notice with the reviewed upstream version and commit.
