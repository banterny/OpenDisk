# OpenDisk — working notes

Security-reviewed fork of [137137137/OpenDisk](https://github.com/137137137/OpenDisk).
Read [SECURITY-REVIEW.md](SECURITY-REVIEW.md) before changing anything in the
deletion, path-guard, or update paths — it explains *why* several things are
written the way they are, and the reasoning is not obvious from the code alone.

## Commands

```bash
# Tests (105). Run these before and after any change.
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
   become deletion candidates, so `InAppFileDropDelegate` accepts a drop only
   while `FileDragSource.shared.activeFiles` is set — a drag begun in this
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

## Syncing from upstream

```bash
git fetch upstream && git diff HEAD upstream/main   # read this before merging
git merge upstream/main
```

Read the diff first — that is the whole point of the fork, since there is no
updater to do it for you. Watch in particular for anything reintroducing
Sparkle, `MoveToApplications`, `removeItem` as the deletion default, string
comparison in `ProtectedPaths`, `.move` in the drag operation mask, or `async`
on the scanner's blocking calls. Re-run the tests after any merge.

In practice a merge is not workable: upstream stripped its comments and the
fork kept them, so nearly every hunk conflicts. What has worked is
`git cherry-pick -n <commit>` one commit at a time, restoring
`OpenDisk.xcodeproj` and `OpenDisk-Info.plist` from `HEAD` after each, then
reading every hunk. Last reviewed upstream commit: `f7551cf` (v1.2.8).

After a port, update what the About box says, in `project.pbxproj` for both
app targets: `MARKETING_VERSION` tracks the upstream release the fork has been
reviewed up to (it is *not* a claim to be that release — see the "not ported"
lists in `SECURITY-REVIEW.md`), `CURRENT_PROJECT_VERSION` is the fork's own
build counter, and `INFOPLIST_KEY_NSHumanReadableCopyright` carries the fork
notice with the reviewed upstream version and commit.
