# Verified portable updates

WUPA 3.2 still ships as one architecture-specific portable EXE, with an embedded offline collector. Updates use the public repository's stable GitHub Releases, not raw files from main, dynamic scripts or a remote command service. No diagnostic evidence is uploaded.

## Operator workflow

1. Download/run 3.2.0 once. Older 3.1.1 binaries have no updater.
2. An eight-second-bounded check runs on GUI startup; **Check for updates** retries explicitly. Collection remains available offline. Checks have no SYSTEM task or background service.
3. **Update available — apply update** asks approval before downloading authenticated code. Engine updates stage locally in a new immutable version folder; future GUI collection uses that engine.
4. For an existing case, approve **Apply engine to this active run**. It acquires the run lock, validates task ownership/state compatibility, preserves the old task XML and state, pauses only the WUPA recorder, redirects the owned task actions, and verifies restart. Existing setup hooks, SetupConfig backup, expiry, RunId and baseline/sample bytes are retained. The pause is a collection gap, not installation duration.
5. If a pass holds the run lock, wait rather than deleting the lock or killing processes. If migration fails, it restores original task/state definitions and verifies the original recorder restart. An unrecovered Pending journal is surfaced; retry the same active-run action to recover it. If rollback/restart remains unverified, do not assume monitoring is healthy: review Collector.log and the journal.
6. A GUI-required release downloads a matching self-contained EXE under ProgramData and offers to launch it. It never overwrites the source EXE/network share and does not silently migrate tasks.

Engine versions and the application version are displayed separately when different. The authenticated cached engine is reverified on launch. Unsupported schemas, downgrades, bad signatures/hashes, undeclared payloads, unsafe paths and off-domain redirects are refused. Downloads/staging use SYSTEM/Administrators-only ACLs; failures retain evidence and do not deliberately change the operating-system upgrade.

## Trust and limitations

The trust root is `Gui/Assets/UpdatePublicKey.pem`, embedded at build time. RSA-PSS/SHA-256 authenticates the exact bytes of `WUPA-update.json`; the manifest binds the engine ZIP, its internal content manifest, and matching executable assets to versions, lengths and hashes. A hash file beside a download alone would not authenticate the publisher.

The original EXE must still come from a trusted distribution. Manifest signing is **not Authenticode signing**, does not automatically establish Windows publisher trust, and does not bypass AllSigned/WDAC/AppLocker/Smart App Control. No application-control weakening is performed. The current portable builds/PowerShell scripts remain unsigned for those policies.

Allowed HTTPS download/redirect hosts are api.github.com, github.com, release-assets.githubusercontent.com and objects.githubusercontent.com. No stored credentials/proxy passwords are used. Organization proxy policies and GitHub anonymous rate limits can make a check unavailable; the embedded/cached collector remains usable. A manifest's compatibility declaration is a maintainer commitment, not proof that arbitrary future state changes are safe.

## Maintainer release process

1. Bump VERSION, application/engine versions and Data/update-compatibility.json; keep tool, schema, UI and state compatibility explicit.
2. Run the PowerShell, native layout and updater tests; regenerate BundleManifest.sha256. Windows CI builds both executables and an unsigned engine ZIP/update JSON artifact. **CI does not hold the private signing key.**
3. Download the validated executables/build record into a fresh release folder. Run `Build/Create-UpdateRelease.ps1 -OutputPath <folder> -SigningKeyPath <offline-private-key.pem> -MinimumAppVersion <minimum-shell-version>`. The script verifies the key against the public key embedded in WUPA. Use a minimum equal to the new GUI version when shell behavior changed; engine-only hotfixes may keep minimum 3.2.0 while their engine/release versions advance.
4. Independently verify the actual signature, ZIP contents, inner manifest and both EXE hashes using the UpdateCore.Tests `--verify-release <folder> <public-key.pem>` mode.
5. Publish one stable version tag with the two EXEs, WUPA-build.json, Checksums.sha256, WUPA-engine-<version>.zip, WUPA-update.json and the binary WUPA-update.sig. Never replace assets under an existing version. No source/temp fixtures, private keys, device logs or inventories belong in the public release.

The initial private key is stored outside the repository in the maintainer's private configuration directory (`.config/wupa-signing/update-private.pem`), with restrictive permissions. Back it up securely; it is not collected or uploaded. Loss/rotation of that key requires a deliberate new trusted EXE deployment. Do not copy it into the repository or add it to general CI secrets. Protect the signing machine and review release artifacts before signing.

## Verification scope

Fixtures cover signature/hash failure, redirects/offline/cancellation, unsafe/duplicate ZIP entries, inner payload changes, interrupted receipts, cached-engine tampering, report-completion proofs, migration lock contention, task registration/restart failure, foreign task ownership, incompatible schemas and interrupted migration recovery. Windows PowerShell 5.1 executes real raw-collector output through the exporter. Native Windows rendering tests are not full Windows feature-upgrade tests; offscreen 1920 rendering and larger-font stress cases are not real multi-monitor DPI validation. Lab results are documented separately in release notes.
