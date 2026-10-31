---
name: principles-scientific-method
description: Evaluate a claim the way a scientist would. Observe, state a falsifiable hypothesis, predict the result before acting, change one thing at a time, compare against a baseline or control, try to prove yourself wrong, and label confidence with evidence. Use when debugging, testing a fix, tuning, benchmarking, comparing two configurations, or before saying "it works", "that was the cause", or "this is faster".
---

# Scientific Method

A result means something only if it could have come out the other way.

## The loop

1. **Observe.** Write down what you actually saw: the metric, the log line, the time window, the machine. Not your reading of it.
2. **Hypothesis.** One sentence that can be false. "The database is the throughput limit" is testable. "Something is slow" is not.
3. **Predict before acting.** Write the expected result first: "if the database is the limit, its CPU or IO saturates and latency rises as offered load rises." A prediction written after the run is a story.
4. **Change one thing at a time.** One knob per run. If two changed, you cannot say which one mattered.
5. **Baseline or control.** Compare to the same setup without the change: the previous build, the old configuration, an untouched replica over the same window. No baseline, no claim.
6. **Try to prove yourself wrong.**
   - A test for a fix must fail without the fix. Revert it and run again, or show the failing run.
   - Ask what else explains the result: a saturated load generator, a deploy in the window, a warm cache, a noisy neighbor, different input sizes.
   - Look for the observation your hypothesis forbids. Finding one kills it.
7. **Label confidence.** Every conclusion gets one label and its evidence:
   - **confirmed**: predicted, observed, alternatives ruled out, linked evidence (graph, run, log).
   - **likely**: fits the evidence, one alternative not ruled out. Say which.
   - **guess**: plausible, not tested. Say what test would settle it.

## Rules

- Write the prediction and the confidence label in the report, not just in your head.
- A negative result is a result. Record it with the same care.
- When the data disagrees with the hypothesis, the hypothesis loses.
- Keep runs comparable: same input, same concurrency, same duration, same machine type.

## Worked example: "the new cache made the API faster"

- Claim: p99 latency dropped from 120 ms to 70 ms after enabling a cache.
- Hypothesis: the cache removes the slow database read on most requests.
- Prediction: if true, the cache hit rate is high, database reads per request fall, and p99 rises back when the cache is disabled with nothing else changed.
- Baseline: the same build with the cache flag off, same traffic replay, same hour.
- Try to break it: the first run was at night with lighter traffic. Rerun both arms on the same replay. The gap shrinks to 120 ms vs 95 ms. Disable the cache: p99 returns to 120 ms.
- Alternative checked: a database index added the same day. Revert it in a test environment: no change, so it does not explain the gap.
- Conclusion: the cache cuts p99 by about 25 ms, not 50 ms. Label: **confirmed** for 25 ms. The other 25 ms was the lighter traffic.

## Output

For each claim: hypothesis, prediction, baseline, result, alternatives checked, confidence label, evidence links.
