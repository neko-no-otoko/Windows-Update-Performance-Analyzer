# WUPA

Windows Update Performance Analyzer is a focused, read-only Windows 11 25H2 update recorder and evidence packager. It observes Windows Update before, during, and after the feature update, then produces a factual timeline and an external-review bundle. WUPA does not install the update, apply repairs, bypass safeguards, or upload evidence.

> WUPA is an independent open-source utility. It is not a Microsoft product and is not affiliated with Microsoft. Do not abbreviate it to WPA; Windows Performance Analyzer is an existing Microsoft tool.

## Use it

1. Download the one-file executable for the computer:
   - `WUPA-3.2.2-win-x64.exe` for most Windows PCs.
   - `WUPA-3.2.2-win-arm64.exe` for Windows on ARM.
2. Run the executable and approve UAC.
3. Select **Start tracking** before the update is offered or installed.
4. Wait for **Ready for the 25H2 update**. You can then close WUPA.
5. Start the update normally from Windows Update, Intune, ConfigMgr, or your existing deployment process.
6. WUPA continues as SYSTEM through downloads and reboots. It automatically creates the report when a terminal result is observed.
7. To finish manually, reopen the same executable and select **Finish tracking and build report**.

If 25H2 is already installed, the primary action becomes **Create report from existing logs**. On an older build, **Already attempted the update? Create a report from existing logs** provides the same after-the-fact collection for a failed or rolled-back attempt. This is retrospective collection, not a guarantee that download/install/reboot boundaries are still available.

## What the operator sees

WUPA has no settings page and no public command-line workflow. The target and safe defaults are fixed:

- Windows 11 25H2 / build family 26200
- 60-second persistent progress sampling
- 30-day tracking expiry
- setup outcome hooks enabled
- local results under Public Documents
- full memory dumps excluded
- no media compatibility scan
- no installed-software inventory
- no DISM health scan, SFC verification, or repair action

The app exposes one state-aware primary button. Links to **Open latest completed report** and **Open report folder** appear only when a report exists. **Stop tracking without a report** is a separate, confirmed action while monitoring. **Show collector log** reveals technical output and **Open tracking files (ProgramData)**; the report-folder link always opens a finalized report folder in Public Documents. The centered, width-limited layout wraps text when resized, scrolls on small windows, and does not resize or restore a maximized window when toggling the log.

## Focused evidence profile

WUPA retains evidence needed to reconstruct Windows Update download, install, reboot, success, failure, or rollback:

- 60-second Windows Update and Delivery Optimization status/counter samples
- HTTP, peer, and Connected Cache byte observations reported by Delivery Optimization
- Windows Update history and pending-reboot state
- `$WINDOWS.~BT\Sources\Panther` and `Rollback`
- `Windows\Logs\MoSetup` and existing SetupDiag results
- Windows Update ETLs plus a readable conversion
- USO and Delivery Optimization native logs, including the NetworkService DO ETL directory
- retained setup performance ETLs in Panther, NewOS, rollback, Windows.old and hook-copy locations (raw context until attributed)
- native Setup, MoSetup, Windows Update, Update Orchestrator, Delivery Optimization, and System event channels
- source/target build identity, storage/WinRE/BitLocker readiness, update policy, core update services, BITS, proxy, clock, problem devices, and update-critical drivers
- state-boundary snapshots of only Panther, Rollback, and MoSetup evidence

Broad software, package, feature, general hardware, MDM, ConfigMgr, WER, SetupAPI, CBS, DISM, reliability-history, network-inventory, and full-dump sweeps are excluded from the default profile.

`Windows\Panther` is also excluded. That location commonly contains deployment or imaging setup activity and is not trusted as feature-update evidence. Setup parsing is restricted to `$WINDOWS.~BT`, rollback, setup-hook copies, and `Windows.old` upgrade evidence, with source, build, time, and contamination gates recorded in the report.

## Upgrade identity and timing

WUPA 3.1 locks the actual target feature update's **UpdateID GUID and revision**, retaining the service identity when exposed. It discovers them from named Windows Update event fields and installation history. There is no hard-coded GUID for every 25H2 deployment. Cumulative, security, driver, .NET, Defender, and other-release updates remain context even when their titles mention 25H2. Unknown/localized titles are not guessed. Multiple target identities are marked ambiguous, missing revision metadata is marked incomplete, and a later update cannot replace an existing lock.

The report's phase table uses matching Windows Update informational events for download start/completion and install start/result. Repeated operation starts have separate records. Missing starts or ends stay unknown; elapsed times include waits and pauses. The first observed target OS after reboot is a separate boundary with actual observation bounds, which may exceed 60 seconds across reboot. Windows Update history dates do not establish download or install start times.

Delivery Optimization FileId identifies a payload file, not the upgrade. Its device-wide counters are labeled context; only an explicit UpdateID mapping can contribute a target download observation. SetupDiag runs after collection only when all recursive setupact inputs describe one validated target session. Logs linked only by target build and an installation window retain `ContextOnly` attribution; stale/global SetupDiag results cannot automatically finish monitoring.

See Microsoft's [update identifier documentation](https://learn.microsoft.com/en-us/windows/deployment/update/windows-update-logs), [SetupDiag offline input behavior](https://learn.microsoft.com/en-us/windows/deployment/upgrade/setupdiag), and [Delivery Optimization status fields](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-monitor).

The report's **Activity by UpdateID** section expands every observed update GUID/revision independently, with its title, update source, download/install intervals, retries, latest events and history results. The 25H2 target appears first. Concurrent drivers or security updates stay visible in their own groups and cannot change the target outcome. Conflicting known services are separated; events without a GUID stay device context. `UpdateActivity.json` and `AllUpdatesTimeline.csv` provide the same breakdown for external review.

Native trace capture recursively attempts every retained `.etl` (including `.etl.old`, `.etl.bak`, and numeric rotations) in the configured Windows Update, USOShared/USOPrivate, both DO log locations, and setup roots. `ETLCoverage.json` inside Evidence.zip lists roots, files, hashes, missing sources and copy failures. Capture happens before log conversion. Final ETL capture has no age or per-file-size exclusion; phase-boundary checkpoints remain bounded and record skipped files. Live traces are copied without flushing/stopping services and labeled `CapturedUnflushed` or `ChangedDuringCapture`; successful copying is not proof of a complete or parseable ETW session. Windows-cleaned or inaccessible files cannot be recovered. No whole-disk ETL search or download-cache payload collection occurs. Windows\\Panther general deployment logs remain excluded; its retained ETLs are raw context only.

Microsoft documents the [NetworkService DO trace path](https://learn.microsoft.com/en-us/windows/deployment/do/delivery-optimization-test) and [Panther setup performance ETL](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-log-files-and-event-logs?view=windows-11).

For full live capture, start tracking before the upgrade. Opening a newer executable does not by itself replace already-running scheduled-task code. WUPA 3.2.2 offers **Apply engine 3.2.2 to this active run** for compatible 3.0.0 through 3.2.1 cases; it retains their original baseline and samples, journals a brief sampling pause, and updates only the owned task actions. Do not cancel/re-arm an ongoing case just to obtain the report fix. Earlier data cannot acquire observations that the older recorder never captured.

The 3.2.2 engine corrects staged ETL filenames and rejects decoder placeholder files. A later matching installation result closes an older start for outcome reporting, but never supplies a missing installation/reboot timing boundary. Missing ends display as **Not retained**, with duration **Not calculable**; they do not independently mean the upgrade is still running. Existing 3.2.1 applications can receive this engine-only fix through the signed updater.

## Verified updates

**Check for updates** checks the public GitHub stable release. A short, non-blocking check also runs when the GUI opens; failed/offline checks do not prevent collection. Nothing is uploaded, no GitHub credentials are stored, and SYSTEM recorder/resume tasks never check for updates.

Downloads require explicit approval. An RSA-PSS signed release manifest, verified using the public key embedded in the EXE, authorizes exact filenames, versions, sizes and SHA-256 hashes. Engine ZIPs are verified inside and outside, extracted with traversal/duplicate/reparse safeguards, and staged in a separate versioned local directory. Merely installing a newer engine does not mutate an active run: use its separate **Apply engine to this active run** link and review the collector status afterward. Busy collectors, incompatible state schemas, and downgrades are refused; interrupted migrations have a recoverable journal and preserve evidence.

Engine-only hotfixes use a small ZIP. Releases requiring a newer GUI download a replacement portable EXE locally and offer to open it; an EXE on a network share is never overwritten. Compatible authenticated cached engines work offline; the embedded engine remains the baseline fallback. The first move from 3.1.1 to 3.2.0 still requires downloading the new EXE once. See [update operations and release signing](docs/UPDATES.md).

## Results

Final results are written to:

```text
%PUBLIC%\Documents\WUPA-<Computer>-<RunId>
```

Start with:

- `Report.html` — focused offline report
- `ReviewBundle.zip` — compact drag-and-drop package for an approved external reviewer or AI utility
- `Evidence.zip` — full retained raw evidence
- `Summary.json`, `RecorderSummary.json`, `Facts.csv`, and `Timeline.csv` — target-focused normalized records
- `UpdateActivity.json` and `AllUpdatesTimeline.csv` — independent activity/results for all observed update identities
- `Collector.log` — collector execution history
- `Manifest.json` and `Checksums.sha256` — provenance and integrity

Durable tracking state is stored in `%ProgramData%\WUPA\Runs\<RunId>`. Temporary scheduled tasks live under `\WUPA\` and are removed, along with WUPA-owned setup hooks, after automatic completion, manual finish, cancellation, or expiry. Diagnostic artifacts are retained.

## Privacy and security

Reports can contain computer names, usernames, domain details, IP addresses, paths, serial numbers, policy data, and raw log content. Treat the output as sensitive. WUPA does not collect passwords, tokens, browser data, Wi-Fi keys, certificate private keys, or BitLocker recovery passwords.

The executable is self-contained and embeds a SHA-256-manifested PowerShell 5.1 engine. The current public build is not organization-signed; environments enforcing WDAC, AppLocker, Smart App Control, or `AllSigned` still require an organization-trusted signing and allowlisting process.

## Build and test

```powershell
pwsh -NoProfile -File .\Tests\Invoke-V300Tests.ps1
.\Build\Update-BundleManifest.ps1 -Verify
.\Build\Build-WindowsExecutables.ps1 -RuntimeIdentifiers win-x64,win-arm64
```

Windows CI builds and validates both self-contained executables. See `docs/WINDOWS-VM-TEST-CHECKLIST.md` for endpoint validation scenarios.

## License and notices

See `NOTICE.md`. Windows, Windows Update, Windows Performance Analyzer, SetupDiag, and related marks are owned by Microsoft.
