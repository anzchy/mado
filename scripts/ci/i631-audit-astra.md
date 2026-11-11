# Delegated #631 audit decision (2026-11-11)

Recorded from gpt-6-astra (high) under the owner's delegation. This is a delegated design call, not owner approval to enable enforcement. The text below is the durable repository copy of the decision.

1. **M1: choose (b), fail closed.** Any individual DA/FNDA count ≥2^63, or otherwise demonstrably wrapped, is invalid evidence. Validate before shard aggregation; positive neighbouring lines, assertions, or another shard cannot repair that artifact. Report every affected path, line/function identity, shard, raw count, provenance, and invalidity reason. Distinguish invalid evidence from uncovered code and reviewed exceptions; never publish a passing eligible-coverage artifact from an invalid run.

   The five current anomalies invalidate the owner-gate coverage PASS. **Block the acceptance batch** until the evaluator is corrected and preflight evidence is valid. Diagnostic investigation may continue. Track root-cause remediation under [#358](https://github.com/anzchy/mado/issues/358), whose existing nondeterminism report does not establish the cause of these counters. That issue is no waiver. Preserve the ten-cold-plus-one-restored protocol; keep `COVERAGE_ENFORCE=false` pending separate approval.

2. **F1: freeze all 17 exact repository-relative paths and whole-source SHA-256 digests**, with reviewed rationale, toolchain and durable decision reference. Reject additions, substitutions, duplicates, digest drift, and executable mappings in excluded files. Additions/replacements require a new reviewed owner decision. Digest refresh requires re-verifying the no-executable-mapping rationale; no automatic regeneration.

3. **M6: source changes invalidate the pin.** The implementer supplies the source diff, old/new digest, mapping identity/location, toolchain and fresh coverage evidence. An independent reviewer must re-verify the exception’s rationale, unchanged symbol identity, zero valid hits, and absence of newly exempted behaviour. The owner or explicitly delegated owner-decider approves the refresh; name both reviewer and approver in the recorded decision. Update manifest, evaluator identity pins and portable decision reference together. Symbol/rationale/toolchain changes require a fresh explicit exception decision. Re-run drift-rejection tests and local/CI parity before freezing the candidate. #637 follows this procedure.

4. **This fix round:** F1/F2; M1–M6, including durable decision text and corrected failure-injection fixtures; L1 wording, L2 dead check, and L4 stale-pointer invalidation. Use RED-first regression tests for behavioural fixes.

   **Still open:** M7’s two historical broken receipts, accepted only with full disclosure; L3 legacy-helper cleanup; M5’s two baseline failures; L5 overhead evidence until the hosted batch completes. No receipt rewriting or clean-TDD claim.
