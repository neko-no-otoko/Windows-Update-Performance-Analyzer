# Changelog

## 3.2.2 - 2026-10-02

- Keep decoder-compatible WindowsUpdate-prefixed names for staged and rotated ETLs; check all input files inside the child process and retain original-to-staged mappings. Raw evidence remains unchanged.
- Preserve known process failures/timeouts even when they create an output file. Include decoder stderr and validate diagnostic content; the 23-byte write-access probe is never accepted as converted evidence or labeled Parsed.
- Correct the download completion keyword mask for WindowsUpdateClient event 41. Recover matching archived download intervals without substituting history timestamps for installation/reboot boundaries.
- Reconcile target starts with later history/source terminal results. Concurrent driver updates remain separate, old successes do not hide newer target retries/failures, and an unclosed historical start alone does not label a target-OS device Upgrade In Progress.
- Keep partially parsed mixed-owner Panther logs unclassified instead of asserting whole-log non-Windows-Update ownership. Preserve imaging exclusions and attribution gates.
- Add sanitized decoder/status regression tests, real child-process error tests, an optional local-only capture replay, native Windows module input-enumeration checks, and a production public-release engine/cache verification probe. Fixture validation does not claim a full Windows feature-upgrade test; see release notes for completed validation scope.

## 3.2.1 — 2026-10-01

- Decode staged current and Windows.old Windows Update ETLs separately, including rotated ETLs using unique scratch names. Record conversion inputs/results; original evidence is untouched.
- Read retained Windows.old System/WU event archives with file provenance. Capture known current Panther diagnostic files after ~BT cleanup; retain imaging/build/window/ownership gates and do not sweep answer files.
- Add versioned, conservative exact-GUID/revision decoded-log rules, source-line provenance, captured-device time-zone normalization, and explicit missing/DST-ambiguous coverage. Unknown messages and cached flags never become phase boundaries; different log streams cannot be paired into invented durations.
- Separate Windows Update reported success from a live-observed build transition and retain native-event versus decoded-log counts. Export direct log facts/coverage in evidence and the reviewer bundle.
- Fix PS5 report punctuation/UTF8 JSON reads. Use the collector's returned report path, bounded nonrecursive discovery, and explicit checksum/manifest failure reasons.
- Require GUI 3.2.1 for this signed update: 3.2.0 downloads a new portable EXE locally rather than pretending an engine ZIP updates GUI behavior.
- Add retained-log, time-zone/DST, scope, report-locator and actual exporter/GUI-verification regression tests. Supplied device evidence is reviewed only locally, never committed or uploaded to CI.

## 3.2.0 — 2026-10-01

- Fix fatal report export when focused raw-copy metadata excludes MEMORY.DMP without a Path field. Preserve excluded, absent, legacy and incomplete metadata accurately; report malformed metadata as coverage gaps rather than strict-mode crashes.
- Prevent partial HTML/fatal exits from being presented as completed reports. Add an exporter pending marker and require matching report/summary/manifest checksum proofs; preserve the actual fatal message in the GUI.
- Add opt-in signed GitHub release downloads with an embedded RSA-PSS verification key, bounded HTTPS checks, exact size/hash/content validation, safe extraction, exclusive staging and offline cache verification. Keep the single portable EXE; newer shells download locally without overwriting network shares.
- Add explicit compatible active-run migration: lock-aware task ownership checks, exact XML/state recovery journals, recorder restart verification and interruption coverage. Retain RunId, baseline, samples, setup hooks/backup and expiry; refuse busy/incompatible/downgrade cases.
- Add real raw-collector/exporter fixtures for retrospective 25H2 and preflight/final 23H2-to-25H2 snapshots, plus legacy/partial/truncated metadata, migration failure/recovery, updater integrity/transport and report-completion tests. Validate Windows PowerShell 5.1 and native layout in CI; record lab scope without claiming a full feature-upgrade run.

## 3.1.1 — 2026-10-01

- Center the native GUI in a width-limited, scrollable layout; remove fixed-width status text and the blank expanding row. Collector-log toggles no longer resize the window or disturb maximized state.
- Use the existing high-resolution WUPA artwork for the header instead of enlarging the small window icon; retain the same logo and application icon.
- Keep one state-aware primary button: Start tracking, Finish tracking and build report, or Create report from existing logs. Use contextual links instead of a row of secondary buttons; hide report links until a report exists.
- Correct report-folder navigation to open only finalized output in Public Documents; expose ProgramData tracking files separately inside the collector-log section.
- Distinguish finish-with-report from stop-without-report, describe retrospective collection honestly, and stop calling every held run lock automatic finalization. Disable conflicting actions for held/unreadable locks. A newer Windows build is no longer labeled 25H2 in the GUI.
- Add native Windows GUI layout/state tests and rendered snapshots at small, normal, wide and maximized sizes, with collector log closed/open and larger-text stress cases. Tests do not start collectors or arm tasks.

## 3.1.0 — 2026-10-01

- Add independent per-UpdateID/revision activity groups to HTML, JSON and CSV exports; keep concurrent update outcomes separate from the target. Preserve conflicting known update services and no-ID context explicitly.
- Capture all retained native/rotated ETLs recursively in focused WU/USO/DO/setup roots before conversion, including the canonical NetworkService DO location and context-only Panther/NewOS traces. Add per-file/root coverage and hashes; bounded checkpoints preserve ETLs where capacity allows. Do not flush/stop services or claim a live trace is complete.
- Lock target feature-update identity using UpdateID/revision and available service identity; persist across reboot and exclude unrelated quality, security, driver, .NET, and other-release updates. Ambiguous identities are not selected automatically.
- Capture informational Windows Update lifecycle XML incrementally from System and WindowsUpdateClient operational channels, with explicit query coverage and bounded final recovery.
- Add identity-matched download/install operation intervals, missing-boundary labels, and separate post-reboot target-OS observation bounds to HTML, Summary.json, standalone JSON, and ReviewBundle.
- Gate SetupDiag before execution against one uncontaminated target setup session; distinguish direct setup GUID attribution from target-build/time context. Skip baseline SetupDiag, and stop treating stale global SetupDiag output or general setup error tokens as automatic finalization signals.
- Treat TiWorker/MoUsoCoreWorker and unmapped DO transfers as context rather than feature-upgrade installation; correct Caching status and use exact target build-family matching.
- Keep UTC JSON strings stable across Windows PowerShell 5.1 and PowerShell 7.5, and preserve WUA history's documented UTC date.
- Add mixed-update, revision/service mismatch, retry, missing-boundary, reboot-gap, unsafe XML, SetupDiag contamination, and report export regression fixtures; execute them on Windows PowerShell 5.1 in CI.

## 3.0.0 — 2026-08-28

- Rebranded the product as **WUPA — Windows Update Performance Analyzer**, with a flat, trademark-distinct navy/teal/amber logo and explicit independent-project notice.
- Replaced the mode-and-settings interface with one state-aware primary workflow: start tracking, finish and report, or analyze retained evidence when 25H2 is already present. Secondary controls are limited to results, existing-log analysis, and cancellation.
- Reduced the public PowerShell interface to `Start`, `Resume`, `Finish`, `Analyze`, and `Cancel`; target 25H2, Public Documents output, 30-day expiry, setup hooks, safe dump behavior, and network behavior are fixed product defaults.
- Moved new durable state, tasks, runtime, launcher log, and results to the `WUPA` name while detecting and refusing to collide with active v2 cases.
- Removed active DISM/SFC health checks, Appraiser refresh, media scan, full memory-dump hashing/copying, software/package/feature inventory, broad hardware/network/management sweeps, reliability history, general WER/SetupAPI/CBS/DISM evidence, and nonessential event channels.
- Kept the focused evidence needed for download/install/reboot performance: recorder samples, Delivery Optimization counters, update history, update policy/services/BITS, core setup/rollback logs, WU/USO/DO native logs, focused event channels, storage readiness, problem devices, and update-critical drivers.
- Excluded `Windows\Panther` from feature-update evidence to avoid imaging/deployment contamination; setup parsing remains gated to `$WINDOWS.~BT`, rollback, setup-hook copies, and `Windows.old` upgrade evidence.
- Reduced state-boundary checkpoints from 64 to 8, limited each to 64 MiB, stopped duplicating event-channel exports at every checkpoint, and retained only the newest bounded Panther/Rollback/MoSetup files.
- Removed CMD launchers, tests, documentation, and other operator-irrelevant files from the embedded executable payload while retaining repository source and regression assets.

## 2.2.1 — 2026-08-28

- Changed the GUI's held-run message to **Automatic post-reboot finalization is already running** and disabled duplicate Finalize/Stop actions while another process actually owns the exclusive run lock.
- Added a five-second live tail of the active run's `Collector.log`; the newest status appears in the status panel, its tooltip, and the GUI progress console even while SYSTEM is writing the file.
- Fixed exit-code `10` handling so a run-lock collision or another no-report result can no longer be labeled **Report created**.
- Removed the broad Software collector and its uninstall, AppX, features/capabilities, language/profile, service, security-product, process, and filesystem-filter enumeration to reduce collection time.
- Kept Windows Setup, CompatData, and Compatibility Appraiser artifacts in scope so source-reported application blocks remain available without general software inventory.
- Marked software collection as `DisabledByDesign` in normalized inventory/review output and suppressed misleading application/service pre/post removals when finalizing an older armed run.

## 2.2.0 — 2026-08-27

- Added a playful magnifying-glass update mascot icon to the GUI executable and taskbar window.
- Added a self-contained Windows Forms operator application for x64 and ARM64. The GUI embeds and verifies the full diagnostic payload, requests elevation, streams collection progress, and exposes Start monitoring, Finalize, Forensic, Disarm, and result-opening actions without command-line parameters.
- Changed Preflight into a strict non-final operation. It now commits the baseline to ProgramData, verifies persistent recorder startup, writes `State\preflight-status.json`, and exits before all report/archive exporters.
- Stopped run-context creation from pre-creating the final Public Documents output directory. `Report.html`, `Evidence.zip`, `ReviewBundle.zip`, manifests, and CSV/JSON result contracts are now published only by automatic Resume, explicit Finalize, or Forensic collection.
- Added a material `RecorderStartFailed` coverage state so the GUI cannot report a healthy armed case when immediate recorder startup was not verified.
- Added deterministic x64/ARM64 build scripts, embedded-payload manifest validation, GitHub Actions artifacts, and v2.2 regression coverage.
- Documented that embedding avoids per-module ZIP download markers but does not bypass AllSigned, AppLocker, WDAC, or the need for organization-trusted signing where those controls apply.

## 2.1.2 — 2026-08-27

- Added a manifest-first extracted-bundle preparation gate for systems where ZIP extraction propagates Internet-zone markers to every PowerShell entry point and module.
- The main CMD launcher now detects marked files before loading PowerShell code, requests one explicit `UNBLOCK` confirmation, recursively removes only `Zone.Identifier` streams inside the verified bundle, confirms removal, and then continues normally.
- Added standalone `Prepare-Win11UpgradeDiag.cmd` with noninteractive `-Check` and `-Apply` modes for approved software-distribution workflows.
- Preparation never calls `Set-ExecutionPolicy` and explicitly stops when Group Policy requires `AllSigned` or `Restricted`; AppLocker, WDAC, Defender, and other application-control enforcement are not bypassed.
- Added Windows-native download-marker, manifest-tamper, policy-boundary, launcher-wiring, and staged-runtime regression coverage.

## 2.1.1 — 2026-08-27

- Fixed Windows PowerShell 5.1 process accounting by retaining the native process handle before timeout polling, preserving explicit exit codes even for commands that terminate immediately.
- Replaced legacy recursive evidence enumeration with an extended-length .NET filesystem walker for manifests and `Evidence.zip`, preventing `Get-ChildItem` from aborting archive creation beyond the Win32 path boundary while still skipping reparse directories.
- Fixed the long-path archive regression fixture cleanup on Windows by deleting the extended-length test tree through the .NET filesystem API before ordinary temporary-directory cleanup.
- Fixed cross-reboot persistence registration by using the Task Scheduler COM folder path without a trailing slash and re-opening the folder when a preceding registration wins the create race.
- Treats an absent `PendingFileRenameOperations` registry value as a normal recorder observation instead of emitting a strict-mode provider error every 60 seconds.
- Added `%PUBLIC%\Documents\Win11UpgradeDiag-Launcher.log` bootstrap logging across the CMD launcher, UAC handoff, integrity validation, module loading, and fatal startup paths so an early failure cannot exit without a durable diagnostic.
- Kept the report schema and fact-only evidence contract unchanged.

## 2.1.0 — 2026-08-26

- Added public `-Mode Finalize` for an operator-controlled end to an armed persistent recording run.
- Finalize records the operator identity, arm-expiry state, Setup-active state, and automatic terminal-signal evaluation before stopping collection.
- Added a forced `OperatorFinalizationBoundary` sample/checkpoint followed by the same full passive-first collection, fact analysis, report, archive, and owned-persistence cleanup used by automatic finalization.
- Kept automatic `Resume` safeguards unchanged: it still defers while Setup is active and still requires direct terminal evidence.
- A successful operator finalization without a directly observed terminal result remains factually labeled; the operator action never implies upgrade success or failure.
- Failed finalization attempts restart the recorder so the armed run remains retryable.
- Final collection now refuses to race a recorder that has not released its per-run lock within the bounded shutdown window.

## 2.0.0 — 2026-08-26

- Added a persistent SYSTEM progress recorder with 60-second append-only JSONL sampling, restart-on-failure behavior, cross-reboot continuity, expiry, and owned cleanup.
- Added state/build/boot/Setup-progress boundary detection and timestamped native checkpoints with per-source copy/export status, hashes, and capacity limits.
- Added first-class Delivery Optimization status, peer, current/month performance, configuration, progress percentage, source-byte, cache-share, and throughput records. Provider failures are explicit instead of silently empty.
- Preserved native Panther, rollback, Windows Update ETL, USO, Delivery Optimization, servicing, event, and crash evidence before readable conversion or active diagnostics.
- Split status into current target presence, observed build transition, attempt outcome, and deployment provenance. A current 25H2 device without retained provenance now reports `Target OS Present`, not `Unknown`.
- Added source-reported Setup phase segmentation for recent run-window Downlevel, SafeOS, FirstBoot, and OOBE markers; historical imaging logs cannot activate a phase by themselves.
- Replaced ambiguous process warnings with explicit `Succeeded`, `ExitedNonzero`, `TimedOut`, `StartFailed`, `ExitCodeUnavailable`, and `ArtifactCapturedDespiteProcessUncertainty` results, including PID, deepest error, and artifact change evidence.
- Added `RecorderSummary.json`, `ProgressSamples.jsonl`, `StateTransitions.jsonl`, and `Checkpoints.json` to final output and the external-review data model.
- Advanced `Summary.json` to numeric schema `2` and semantic schema `2.0.0`, while keeping the fact-only and strict Windows Update scope model.
- Added v2 fixture tests for recorder state sequencing, JSONL truncation recovery, Delivery Optimization arithmetic, target/provenance separation, checkpoint creation, and process accounting.

## 1.1.2 — 2026-08-26

- Hardened `Evidence.zip` and `ReviewBundle.zip` source reads for Windows PowerShell 5.1 by retrying local and UNC files with Windows extended-length paths.
- Evidence hashing now uses the same long-path-aware, read/write/delete-sharing stream logic as archive construction.
- Opens each evidence source before creating its ZIP entry, preventing an unavailable source from leaving a misleading empty entry.
- Indexes filesystem reparse points without following their targets outside the staged evidence tree; they are explicitly recorded as optional archive exclusions.
- Adds factual archive-failure classifications for a genuinely missing source, a remaining long-path failure, and another read failure, including path length, existence-at-failure, and reparse status.
- Added a regression that hashes and archives evidence from a path longer than 300 characters.

## 1.1.1 — 2026-08-26

- Standardized the default finalized-output parent for interactive and SYSTEM runs on `%PUBLIC%\Documents` (`C:\Users\Public\Documents` on a standard installation).
- Final reports, normalized exports, `Collector.log`, `ReviewBundle.zip`, `Evidence.zip`, and integrity manifests now remain together in a unique `Win11UpgradeDiag-<Computer>-<RunId>` folder under Public Documents unless the operator explicitly supplies `-OutputPath`.
- Existing armed runs continue using their saved output path so a single pre/post run is never split between destinations.

## 1.1.0 — 2026-08-26

- Replaced default causal rule correlation with a fact-only evidence engine. The tool now emits `Observed`, `SourceReported`, `Decoded`, and transparent `Computed` records without naming a root cause.
- Added a provider-neutral `ReviewBundle.zip` with case metadata, attempts, JSONL/CSV facts and timeline, complete Windows Update history, inventory/diff, coverage, excluded-evidence records, hashed evidence index, bounded excerpts, and a ready-to-use external-review prompt.
- Added strict setup-attempt gates for Windows Update ownership, feature-upgrade semantics, time overlap, target version/build, completed Windows image state, and contamination exclusions.
- Explicitly classifies and excludes initial deployment/imaging, diagnostic compatibility scans, general servicing, non-Windows-Update upgrades, unclassified setup evidence, and tool-generated evidence from the included upgrade timeline.
- Reordered collection so passive raw evidence is snapshotted before DISM, SFC, Appraiser refresh, media scan, or SetupDiag execution. DISM now writes to a run-owned log path and SetupDiag receives only a scoped feature-upgrade source.
- Added Windows image-state capture and richer Windows Update history provenance (`UpdateID`, revision, client application, service, and server selection where exposed).
- Fixed Windows PowerShell 5.1 launch failures for no-argument commands by omitting an empty `Start-Process -ArgumentList` binding.
- Fixed strict-mode failures on sparse uninstall and process records, including missing `DisplayName` and `Name` properties, and added script-location detail to collector/fatal errors.
- Added v1.1 regression fixtures for real upgrade, imaging, scan-only, sparse-object, contamination-order, review-bundle, and fact-only report contracts.

## 1.0.0 — 2026-08-25

- Initial 23H2 → 25H2 diagnostic companion.
- Added one-click elevated launcher and PowerShell 5.1 engine.
- Added preflight, automatic resume, forensic, and disarm modes.
- Added guarded SetupConfig hooks and SYSTEM scheduled-task persistence.
- Added Windows Setup, compatibility, servicing, update, driver, policy, management, event, crash, and inventory collectors.
- Added Microsoft-signed SetupDiag refresh and offline `/NoTel` execution.
- Added deterministic rules, phase/operation decoding, attempt inventory, timelines, confidence, and evidence references.
- Added self-contained HTML, JSON, CSV, ZIP, manifest, and checksum outputs.
- Added exact-byte SetupConfig preservation/restoration, evidence-source mappings, bounded UNC transfer, and ordinary-reboot resume gating.
- Added fixture runner, Pester tests, and Windows VM acceptance checklist.
