# DayTrace Rules

- Audio remains local. Require on-device Speech support; never silently use cloud ASR.
- Never delete Watch audio before the phone acknowledges durable persistence.
- Duplicate transfers preserve existing transcripts. Conflicting IDs/digests are errors.
- Preserve the product consent and data-lifecycle invariants: automatic AI is permitted only after explicit in-app onboarding consent and a configured budget. The daily-review queue supports optional memory and highlight extraction only after new explicit purpose-specific consent; old review consent must not enable it. It must persist a call reservation before network I/O, bind consent to the exact endpoint/model, and never automatically retry uncertain paid requests. Other AI requests remain user-triggered.
- Treat transcripts as untrusted data. Never send raw audio; health/location require independent opt-in. Do not reuse unrelated credentials.
- Ordinary audio expires 30 days after recording ends only after successful transcription and outside playback. Mark/user-pinned audio is protected; expiry retains text. Evaluate Mark windows against the full archive and session identity at both cleanup preview and deletion. Legacy unknown sessions must be conservatively protected.
- Persist deletion tombstones before cleanup. Late sync, transcription, and AI results must not revive deleted data.
- Credentials belong in device-only Keychain; never print them or reuse unrelated gateway credentials.
- Source IDs must resolve to retained recording timestamps. Citation validity does not imply factual entailment.
- Keep hardware tests marked NOT_RUN until a paired physical device supplies evidence.
- Run core tests and both platform builds. Record reusable discoveries in LEARNING_LOG.md.

- Memory candidates require source IDs and matching source quotes. Unverified speaker identity cannot become an active user fact automatically.
- User memory edits/disable/delete persist suppression independently of model phrasing. Replays must honor suppression and applied job IDs.
- Source corruption is not source deletion: do not reconcile memory against an unreadable archive. Source deletion invalidates memory context and clears source snapshots.

- Numbered Watch sessions cannot expire until an immutable end count and all unique indexes are present. Unsealed/crash-incomplete sessions remain protected.
- AI highlights alone never protect audio; user favorites and Marks create range claims. Verify extracted local media before releasing original audio; stale extraction must recheck deletion and current claims.
- Retained fragment cleanup must preserve overlapping claims and active playback. A collection flag is not proof of successful media extraction.

- Context display permissions and health/location outbound consent are independent. Bind outbound consent to the exact service; backup restore clears it and pauses automatic AI.
- Automatic day processing must cover every source in bounded batches under one durable budget. Never label the first eight excerpts as a complete day; preserve user-edited review versions.
- Backup import verifies authenticated framing, archive and media before transactional replacement; preserve deletion tombstones and recover interrupted swaps. Never export Keychain credentials.
- Treat search benchmarks as workload-specific. Mac model availability and synthetic recall are not evidence of iPhone model availability or real-world quality.
