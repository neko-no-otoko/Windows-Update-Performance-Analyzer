# WUPA operations

## Normal workflow

1. Run the architecture-appropriate `WUPA-3.2.0-win-*.exe` as an administrator.
2. Select **Start tracking**.
3. Do not begin the update until the app says **Ready for the 25H2 update**.
4. Close the app if desired and run the update through the organization's existing system.
5. WUPA samples progress every 60 seconds as SYSTEM and restarts its recorder at boot.
6. A terminal setup/update result triggers delayed automatic final collection. Reopen WUPA to view status.
7. Select **Finish tracking and build report** only when an operator intentionally wants to stop tracking and capture the current state. Later update activity will not be recorded.

WUPA never starts the Windows upgrade.

## State-aware controls

- No case and pre-25H2: **Start tracking**.
- Active case: **Finish tracking and build report**.
- Active collection or an unreadable run lock: finish/stop actions are disabled; check **Show collector log** for details.
- 25H2 already installed: **Create report from existing logs**. This collects retained evidence; it does not prove a completed Windows Update upgrade or invent missing timings.
- Pre-25H2 after a failed attempt: **Already attempted the update? Create a report from existing logs**.
- Active case: **Stop tracking without a report** removes owned persistence without creating a report, after confirmation.
- Completed reports: **Open latest completed report** / **Open report folder**, visible only when a report exists. The folder link opens Public Documents output, not staging.
- Technical output: **Show collector log** / **Hide collector log**. **Open tracking files (ProgramData)** is available inside the expanded section while a case is active.
- Updates: **Check for updates** / **Update available — apply update**. A signed download does not migrate existing tasks until the separate active-run action is approved.
- Compatible older/pending cases: **Apply engine 3.2.0 to this active run**. This preserves recorded evidence, journals a brief pause, and verifies recorder restart. Review its status afterward. Do not cancel/re-arm the case to obtain the report fix.

## Paths

- Active pointer: `%ProgramData%\WUPA\ActiveRun.json`
- Durable run: `%ProgramData%\WUPA\Runs\<RunId>`
- Extracted runtime: `%ProgramData%\WUPA\Runtime\3.2.0`
- Scheduled tasks: `\WUPA\Resume-<RunId>` and `\WUPA\Recorder-<RunId>`
- Final output: `%PUBLIC%\Documents\WUPA-<Computer>-<RunId>`
- Early startup log: `%PUBLIC%\Documents\WUPA-Launcher.log`
- Verified update staging and receipts: `%ProgramData%\WUPA\Updates`
- Active-run update recovery journals: `%ProgramData%\WUPA\Runs\<RunId>\State\Updates`

A written HTML file is not a completion signal. `Report.pending` marks an unfinished exporter; report links require matching HTML/summary/manifest checksums. Fatal code 40 is not presented as a completed report even if some artifacts exist.

Finish, automatic completion, cancellation, and expiry remove only the tasks and SetupConfig entries owned by that case. Original SetupConfig bytes are restored when safe. Collected evidence is retained.

## Existing v2 cases

WUPA 3 uses a new state root and refuses to start while `%ProgramData%\Win11UpgradeDiag\ActiveRun.json` exists. Finish or cancel that case with Windows Update Analytics 2.2.1 first. This prevents two recorders and two hook sets from claiming the same update.

## Result handling

Open `Report.html` for human review. Use `ReviewBundle.zip` for drag-and-drop review in an approved external utility. Use `Evidence.zip` when the reviewer needs native logs. Validate files with `Checksums.sha256` before transferring them.

Exit codes remain: `0` complete/ready, `10` attention, `20` failed or rolled back, `30` materially incomplete, `40` fatal tool failure, and `50` unsupported or not elevated.
