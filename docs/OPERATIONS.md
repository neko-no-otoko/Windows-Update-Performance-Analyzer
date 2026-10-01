# WUPA operations

## Normal workflow

1. Run the architecture-appropriate `WUPA-3.1.0-win-*.exe` as an administrator.
2. Select **Start tracking the 25H2 update**.
3. Do not begin the update until the app says **Ready for the 25H2 update**.
4. Close the app if desired and run the update through the organization's existing system.
5. WUPA samples progress every 60 seconds as SYSTEM and restarts its recorder at boot.
6. A terminal setup/update result triggers delayed automatic final collection. Reopen WUPA to view status.
7. Select **Finish and create report** only when an operator intentionally wants to stop tracking and capture the current state.

WUPA never starts the Windows upgrade.

## State-aware controls

- No case and pre-25H2: **Start tracking the 25H2 update**.
- Active case: **Finish and create report**.
- Active automatic collection: primary action is disabled and the last `Collector.log` status is displayed.
- 25H2 already installed: **Analyze the completed 25H2 update**.
- Pre-25H2 after a failed attempt: **Analyze existing update logs**.
- Active case: **Cancel tracking** removes owned persistence without creating a report.

## Paths

- Active pointer: `%ProgramData%\WUPA\ActiveRun.json`
- Durable run: `%ProgramData%\WUPA\Runs\<RunId>`
- Extracted runtime: `%ProgramData%\WUPA\Runtime\3.1.0`
- Scheduled tasks: `\WUPA\Resume-<RunId>` and `\WUPA\Recorder-<RunId>`
- Final output: `%PUBLIC%\Documents\WUPA-<Computer>-<RunId>`
- Early startup log: `%PUBLIC%\Documents\WUPA-Launcher.log`

Finish, automatic completion, cancellation, and expiry remove only the tasks and SetupConfig entries owned by that case. Original SetupConfig bytes are restored when safe. Collected evidence is retained.

## Existing v2 cases

WUPA 3 uses a new state root and refuses to start while `%ProgramData%\Win11UpgradeDiag\ActiveRun.json` exists. Finish or cancel that case with Windows Update Analytics 2.2.1 first. This prevents two recorders and two hook sets from claiming the same update.

## Result handling

Open `Report.html` for human review. Use `ReviewBundle.zip` for drag-and-drop review in an approved external utility. Use `Evidence.zip` when the reviewer needs native logs. Validate files with `Checksums.sha256` before transferring them.

Exit codes remain: `0` complete/ready, `10` attention, `20` failed or rolled back, `30` materially incomplete, `40` fatal tool failure, and `50` unsupported or not elevated.
