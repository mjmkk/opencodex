# AGT-12 relay generation closeout

This is a preservation branch for completed, bounded AGT-12 work. Human stopped continued execution on 2026-10-23; Goal and ownership remain. No new experiment, deployment, service change, request, or test rerun was performed for this archive.

## Provenance and merge decision

The production integration was originally copied from the Mac OpenCodex project. Its Linux production directory and the frozen candidate have no verified Git history. The original Mac repository was confirmed as `https://github.com/mjmkk/opencodex.git`; this archive is an additive commit based on its then-current main `1d34372bb51372b7cd61b716021654c9019dfb94`. That hosting base is **not** asserted to be the source revision of the production bytes.

The checked main has neither `codex-worker-mvp/src/desktop-relay-client.js` nor its test. Consequently the runtime changes are not merged into main. This branch preserves the exact source, old baseline and complete frozen native test inputs together, rather than claiming a compatible two-file patch. Other application files are unchanged.

## Completed work and existing evidence

The runtime source changes only the child lifecycle: a new independent list can establish a new generation after the failed child closes; reads and uncertain responses are never replayed, old-generation events cannot affect the new one, and explicit close is terminal. The original raw JSON/typed IDs and adapter request/owner/version/receipt guards remain.

- Candidate source SHA256: `db34a0c8e65f57e7e88ed498e0a62f524305ee995956c9d33f6fe1dff7249783`.
- Candidate test SHA256: `524a0e635cdc766620b369099e026034a0ffcae13b3b6347e6582db9cc910a29`.
- Existing final Node result: 13 pass / 0 fail; original Python guard result: 9 pass / 0 fail. `VERIFICATION.json` binds the exact inputs, commands, versions and logs. These tests were not rerun during closeout.
- `RED-BEFORE.log` and `TEST-AFTER-1.log` preserve the first failure and intermediate run. The original stage `RESULT.md` and other documents retain their historical pre-adoption statements unchanged.
- The source was subsequently adopted on the existing Linux integration with one mobile-service restart and no rollback; Root already performed scoped engineering/adoption L1. On closeout the deployed file was compared byte-for-byte with the archived candidate. This is not a fresh runtime or device test.
- Adoption, actual checks, 66-file evidence package and independent L1: https://linear.app/mjmk/issue/AGT-12#comment-eb7838f0-6898-493e-8fbe-f5af718a98af . Formal evidence attachment: `6821bbfb-3a64-463c-8f1c-b8d94bf926fa`.

## Recovery and unresolved scope

`baseline/src/desktop-relay-client.js` is the exact prior source (SHA256 `4b61fd1ed0dc97e46086fa41b9096766a62d2aa7792ecc99680628f6f13655a2`). `ROLLBACK-AT-ADOPTION.md` preserves the then-approved bounded restore rules; it does not authorize an automatic future restart or replay. Production permissions/configuration, private archives, credentials, databases and Desktop packaged code are excluded.

A live Python child with a closed internal IPC connection is not healed by this change. The original first-start error cause remains unknown. Genuine Human request/response to the same owner and original-turn continuation, full V1, current iPhone network/UI and Human acceptance are unproven. The later phone TLS failure is not erased by an earlier or different-client successful probe. No claim of complete mobile runtime source backup or accepted mainline integration is made.

Closeout and idle decision: https://linear.app/mjmk/issue/AGT-12#comment-94cc2ba4-3f82-4567-b4a2-dd4d4e714067 .
