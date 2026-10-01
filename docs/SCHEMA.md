# WUPA output schema

## Versioning policy

WUPA 3 retains numeric schema version `2` and semantic schema version `2.0.0` so existing fact-only review consumers remain compatible. Consumers should ignore unknown properties and preserve `null` as distinct from empty or zero. The application, target map, parser data, and output schema are versioned independently.

## Summary.json

`Summary.json` remains the stable fleet-ingestion contract. Its machine-readable draft 2020-12 schema is `Data/Summary.schema.json`.

Core properties are:

| Property | Meaning |
|---|---|
| `AnalysisMode` | `FactOnly` for the v2 default engine. |
| `Device`, `SourceOs`, `CurrentOs`, `TargetOs` | Normalized device and Windows identities. |
| `Outcome` | Human-readable banner derived from the explicit status fields; never `Unknown`. |
| `StatusModel` | Separate `CurrentOsState`, `BuildTransition`, `AttemptOutcome`, and `DeploymentSource` values. |
| `Recorder` | Sampling window, state boundaries, and Delivery Optimization observation rollups. |
| `UpgradeIdentity` | `Locked`, `Ambiguous`, `Incomplete`, or `NotObserved`; target UpdateID GUID/revision, available service identity, discovery evidence, and candidates. |
| `UpgradeTiming` | Identity-matched operation sessions with source-event start/end, missing-boundary labels, elapsed seconds, and separate target-OS observation bounds. |
| `UpdateActivity` | Independent GUID/revision/service activity groups and a combined identity-tagged timeline. Other update outcomes never change the target outcome. |
| `Facts`, `FactCounts` | Direct records and rollups by fact type and scope. |
| `Attempts`, `AttemptScope` | Setup candidates, exact gates, classifications, and validated/excluded counts. |
| `ExcludedEvidence` | Candidate evidence prevented from entering upgrade conclusions and the exact reason. |
| `CollectionCoverage`, `CollectionGaps` | Collector state and known limitations. |
| `ArtifactHashes`, `ReviewBundle` | Output metadata and compact-review-package hash. |
| `PrimaryFinding`, `Findings`, `FindingCounts` | Compatibility fields retained for 1.x consumers. They are `null`/empty/zero in fact-only mode. |

V2 can emit `Monitoring Armed`, `Target OS Present`, `Upgrade In Progress`, `Upgrade Succeeded`, `Rolled Back`, `Failed`, or `No Upgrade Outcome Observed`. Compatibility values `Ready`, `Attention Required`, and `Blocked` remain accepted by the schema. A banner is not deployment provenance; use `StatusModel.DeploymentSource` for that question.

3.1 adds optional `UpgradeIdentity` and `UpgradeTiming` fields without changing the existing numeric schema. The same objects are exported as standalone JSON and in the review bundle. `TargetUpdateEvents.jsonl` contains matching lifecycle XML/fields; `UpdateEvents.jsonl` retains all sampled WU events as context. `UpdateEventCoverage.jsonl` records per-channel query failures/truncation. Native EVTX is retained independently. `Timeline.csv` adds `UpdateID`, `RevisionNumber`, `ScopeStatus`, and `TimingKind`; older timeline rows may leave these fields empty.

Timing sessions separate each source start and terminal boundary. Missing start/end/duration is `null`, never zero. `SourceEvent` means a provider timestamp; `ObservationBound` means the true transition falls between observations, not that either timestamp is the exact transition. `InstallReportedSucceeded` is the WUA applied-operation result; post-reboot target presence is `TargetOsFirstObserved`. `TargetBuildAndIdentityInstallWindow` setup attribution is context only, while `ExplicitSetupUpdateId` has a direct GUID link. DO FileId/URLs alone never link a transfer to the target update.

The status dimensions are:

```text
CurrentOsState   = TargetPresent | TargetNotPresent | Unreadable
BuildTransition  = Observed | NotObserved
AttemptOutcome   = Succeeded | Failed | RolledBack | InProgress | NotObserved
DeploymentSource = WindowsUpdateConfirmed | OtherConfirmed | Unattributed
```

## Fact object

`UpdateActivity.json` contains every observed GUID/revision group with independent `Timing`, `Events` and `History`. `AllUpdatesTimeline.csv` (also `.jsonl` in ReviewBundle) tags each row with `ActivityKey`, `UpdateID`, `RevisionNumber`, `ServiceID`, and `Role`. Known conflicting services split groups; no-ID events remain raw device context. These additive exports never alter the target outcome.

`ETLCoverage.json` in each native snapshot lists trace roots and files, including byte length, SHA-256, and `CapturedUnflushed`, `ChangedDuringCapture`, `PartialCapture`, or `CopyFailed`. An unflushed live copy is not proof of a complete/parseable trace. Absent or unenumerable roots are explicit. ReviewBundle's `NativeTraceCoverage.json` aggregates these records for review. Checkpoint capacity exclusions are recorded separately in checkpoint manifests. Trace files remain in Evidence.zip, not in the compact review bundle.

| Property | Meaning |
|---|---|
| `FactId` | Run-unique sequential identifier. |
| `FactType` | `Observed`, `SourceReported`, `Decoded`, or `Computed`. |
| `Category` | Identity, attempt scope, Setup, Windows Update history, code, coverage, or collector execution. |
| `Statement` | Neutral statement of record. |
| `Value` | Scalar or structured source value. |
| `TimestampUtc` | Source timestamp when available. |
| `AttemptId` | Validated setup candidate identifier when directly attached. |
| `Code`, `Phase`, `Operation` | Source code and deterministic Setup decode, when available. |
| `ScopeStatus` | `Included`, `ContextOnly`, or `Excluded`. |
| `EvidenceRef` | Archive-relative path plus line, array index, event ID, or JSON property locator. |
| `Excerpt`, `ExcerptFile` | Bounded source text and its file inside `ReviewBundle.zip`. |

The types have deliberately narrow meaning:

- `Observed`: directly read by the collector.
- `SourceReported`: emitted by Windows Update, Windows Setup, or scoped SetupDiag.
- `Decoded`: deterministic numeric/symbolic or phase/operation lookup.
- `Computed`: transparent diff or Boolean scope gate; never a root-cause assertion.

## Attempt object

Every `setupact*.log` candidate is inventoried. Important fields include source path/hash, time window, source/target build, parsed codes, content signals, corroborating evidence, classification, and `IncludedForUpgradeReview`.

The `Gates` object exposes every Boolean decision:

```text
UniqueEvidence
NotDiagnosticScan
NotToolGenerated
NotInitialDeploymentOrImaging
FeatureUpgradeSemantics
WindowsUpdateOwnership
TemporalOverlap
TargetVersionOrBuild
CompletedWindowsImageState
```

Only an attempt for which every gate is true receives `WindowsUpdateFeatureUpgrade`. Other classifications are `NonWindowsUpdateFeatureUpgrade`, `DiagnosticCompatibilityScan`, `CurrentHealthDiagnostic`, `GeneralWindowsServicing`, `InitialDeploymentOrImaging`, `UnclassifiedSetupEvidence`, and `ToolGenerated`.

## ReviewBundle.zip

The provider-neutral review bundle contains:

```text
READ_ME_FIRST.md
REVIEW_PROMPT.md
Case.json
RecorderSummary.json
ProgressSamples.jsonl
StateTransitions.jsonl
Checkpoints.json
Attempts.json
Facts.jsonl
Facts.csv
Timeline.jsonl
Timeline.csv
UpdateHistory.jsonl
Inventory.json
InventoryDiff.json
CollectionCoverage.json
ExcludedEvidence.json
EvidenceIndex.jsonl
Excerpts/FACT-*.txt
Manifest.sha256
```

`ReviewBundle.zip` intentionally contains bounded excerpts and normalized records rather than duplicating all raw logs. Use `Evidence.zip` when the reviewer needs complete source content. Both artifacts remain local unless the operator explicitly copies or uploads them.

## Timeline.csv and Timeline.jsonl

The fact-only timeline contains only:

```text
TimestampUtc, AttemptId, FactId, EventType, Code, Phase, Operation,
Message, EvidenceReference
```

Setup rows must originate in a validated Windows Update attempt. Windows Update history rows are retained as source-reported context and are not attached to a setup attempt merely because their timestamps are nearby. Recorder boundary rows use event type `RecorderState`, remain context-only, and do not receive an attempt ID by temporal proximity.

## Findings.csv

The file is retained for compatibility with v1.0 workflows. It contains only its header in fact-only mode. Consumers should migrate to `Facts.csv` or `ReviewBundle.zip/Facts.jsonl`.

## Inventory and integrity

`ProgressSamples.jsonl` is append-only. Each valid line is an independent JSON object; a truncated final line is reported and ignored without losing earlier records. `StateTransitions.jsonl` contains signature boundaries. `Checkpoints.json` rolls up the native checkpoint manifests whose full files remain in `Evidence.zip`.

`Inventory.json` contains baseline/current normalized snapshots and a transparent section-level diff. `Manifest.json` indexes raw evidence and finalized artifacts with paths, sizes, timestamps, SHA-256, source mappings, gaps, and archive verification. `Checksums.sha256` hashes the finalized top-level artifacts. The review bundle has its own internal `Manifest.sha256`.

## Exit precedence

1. Materially incomplete report: `30`.
2. Validated rollback or source-reported failed Windows Update attempt: `20`.
3. Direct attention state reserved for supported future checks: `10`.
4. Complete fact report without a failed/rollback outcome: `0`.

`0` is not a guarantee that an upgrade is ready or will succeed. Fatal startup/report failure (`40`) and unsupported platform/privilege (`50`) occur outside normal report classification.
