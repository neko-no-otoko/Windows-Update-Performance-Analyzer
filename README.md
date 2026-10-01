# WUPA

Windows Update Performance Analyzer is a focused, read-only Windows 11 25H2 update recorder and evidence packager. It observes Windows Update before, during, and after the feature update, then produces a factual timeline and an external-review bundle. WUPA does not install the update, apply repairs, bypass safeguards, or upload evidence.

> WUPA is an independent open-source utility. It is not a Microsoft product and is not affiliated with Microsoft. Do not abbreviate it to WPA; Windows Performance Analyzer is an existing Microsoft tool.

## Use it

1. Download the one-file executable for the computer:
   - `WUPA-3.1.0-win-x64.exe` for most Windows PCs.
   - `WUPA-3.1.0-win-arm64.exe` for Windows on ARM.
2. Run the executable and approve UAC.
3. Select **Start tracking the 25H2 update** before the update is offered or installed.
4. Wait for **Ready for the 25H2 update**. You can then close WUPA.
5. Start the update normally from Windows Update, Intune, ConfigMgr, or your existing deployment process.
6. WUPA continues as SYSTEM through downloads and reboots. It automatically creates the report when a terminal result is observed.
7. To finish manually, reopen the same executable and select **Finish and create report**.

If 25H2 is already installed, the primary action becomes **Analyze the completed 25H2 update**. On an older build, **Analyze existing update logs** provides the same after-the-fact collection for a failed or rolled-back attempt.

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

The app exposes one state-aware primary button plus **Open latest report**, **Open results folder**, and **Cancel tracking** when relevant. Technical logs are hidden unless expanded.

## Focused evidence profile

WUPA retains evidence needed to reconstruct Windows Update download, install, reboot, success, failure, or rollback:

- 60-second Windows Update and Delivery Optimization status/counter samples
- HTTP, peer, and Connected Cache byte observations reported by Delivery Optimization
- Windows Update history and pending-reboot state
- `$WINDOWS.~BT\Sources\Panther` and `Rollback`
- `Windows\Logs\MoSetup` and existing SetupDiag results
- Windows Update ETLs plus a readable conversion
- USO and Delivery Optimization native logs
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

For full live capture, cancel or finish an existing 3.0 monitoring run and start a new run with 3.1 before the upgrade. Opening a newer executable does not replace already-running scheduled-task code. After-the-fact analysis can only recover events Windows retained.

## Results

Final results are written to:

```text
%PUBLIC%\Documents\WUPA-<Computer>-<RunId>
```

Start with:

- `Report.html` — focused offline report
- `ReviewBundle.zip` — compact drag-and-drop package for an approved external reviewer or AI utility
- `Evidence.zip` — full retained raw evidence
- `Summary.json`, `RecorderSummary.json`, `Facts.csv`, and `Timeline.csv` — normalized machine-readable records
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
