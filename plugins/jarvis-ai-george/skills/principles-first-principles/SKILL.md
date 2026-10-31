---
name: principles-first-principles
description: Evaluate a number or a design from fundamentals instead of analogy. Break the problem into its physical parts, compute the bound (cores x per-core rate, network and disk bandwidth, memory, latency, queueing) with a back-of-envelope Fermi estimate, compare the claim to the bound, and question inherited assumptions. Use for capacity and throughput targets, benchmark plans, thread and pool sizing, "is X possible", "what is the bottleneck", or when a design copies another system's numbers.
---

# First Principles

Before trusting a number, compute what physics allows. A claim far above the bound is wrong. A result far below it means something else is the limit.

## Method

1. **Break it down.** Name the resources the work actually uses: CPU, memory, network, disk, a downstream service, threads, locks, a queue.
2. **Estimate each bound.** Fermi style: round numbers, one significant figure, units written out.
   - CPU: cores x work per core per second.
   - Network or disk: bandwidth / bytes per request.
   - Memory: count x size per item, against the heap or host.
   - Latency: requests in flight = rate x latency (Little's law). A pool of N threads with latency L caps at N / L requests per second.
   - Queueing: wait time grows sharply above about 70 to 80% utilization.
   - OS limits: threads per user (`ulimit -u`), file descriptors, ports.
3. **Find the smallest bound.** That is the predicted bottleneck.
4. **Compare the claim to the bound.** Above the bound: the claim is impossible as stated. Far below: find what else limits it (often the load generator or a downstream).
5. **Question inherited assumptions.** "The docs say 20k", "the old cluster had 10 nodes", "the default pool is 16". Ask where the number came from and whether its conditions still hold.
6. **Reason from constraints, not analogy.** "Company Y does it" is a hypothesis. Recompute with this system's sizes.

## Rules

- Show the arithmetic, with units, so a reviewer can check it in ten seconds.
- An estimate within 2x is good enough to decide. Do not polish it.
- When the measured result and the bound disagree, one of them is wrong. Find out which (`principles-scientific-method`).

## Worked examples

**Can one server ingest 50k writes per second of 4 KB each?**

- Demand: 50,000 x 4 KB = 200 MB/s, about 1.6 Gbps.
- Network: 10 Gbps NIC. Fine, 6x headroom.
- Disk: one SSD with about 500 MB/s sustained writes. Fine at 200 MB/s, but replication x3 makes it 600 MB/s. Over the bound.
- CPU: 16 cores at about 20k small writes per core per second = 320k. Fine.
- Verdict: disk is the bottleneck once replication is counted. Either more disks, fewer replicas on the hot path, or a lower target.

**Thread-per-connection at 2,000 connections**

- Threads: 2,000 connections x 1 thread + 50 shared = 2,050.
- Memory: 2,050 x 1 MB default stack = about 2 GB of stack alone.
- OS limit: a per-user thread limit of 4,096 leaves headroom for one restart overlap, not two.
- Verdict: works today, fails at about 2x growth. Move to a bounded pool or async IO before growth, not after a crash.

## Output

A short table: resource, bound with arithmetic, measured or claimed value, gap, verdict. Then the bottleneck and the inherited assumptions you challenged.
