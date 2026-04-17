#!/usr/bin/env python3
# WebSocket round-trip latency benchmark.
#
# For each sample: send an input record with a unique tick_seq, then
# drain incoming frames until one arrives whose tick_seq matches. That
# gives true end-to-end latency for *this* request, not "time to pull
# whatever's already buffered" (which was dominating the p50 in async
# mode and making the numbers meaningless).
#
# In sync (produce-path) mode almost all frames will be the matching
# one on the first recv — the producer's ack blocks until the output
# is committed, so no other frames are in flight.
#
# In async (post-write) mode the first recv typically returns a stale
# frame from a prior tick; we keep draining until the matching seq
# arrives. Count how many we drained too, so we can see async's
# batching characteristics.

import argparse
import asyncio
import struct
import sys
import time

try:
    import websockets
except ImportError:
    print("pip install websockets", file=sys.stderr)
    sys.exit(2)


async def run(url: str, n: int, warmup: int, pace_ms: float) -> None:
    async with websockets.connect(url) as ws:
        # Warmup: pay init cost + drain any pre-existing buffer.
        base = 1_000_000
        for i in range(warmup):
            seq = base + i
            await ws.send(struct.pack("<IB", seq, 0))
            # Drain until we see our seq.
            while True:
                frame = await ws.recv()
                if int.from_bytes(frame[:4], "little") == seq:
                    break

        samples = []
        drained_counts = []
        base = 2_000_000
        for i in range(n):
            if pace_ms > 0:
                await asyncio.sleep(pace_ms / 1000.0)
            seq = base + i
            t0 = time.perf_counter()
            await ws.send(struct.pack("<IB", seq, 0))
            drained = 0
            while True:
                frame = await ws.recv()
                if int.from_bytes(frame[:4], "little") == seq:
                    break
                drained += 1
            samples.append((time.perf_counter() - t0) * 1000)  # ms
            drained_counts.append(drained)

    samples.sort()

    def pct(p):
        k = min(int(p / 100 * len(samples)), len(samples) - 1)
        return samples[k]

    total_ms = sum(samples)
    avg_drained = sum(drained_counts) / len(drained_counts)

    print(f"bench: {n} round-trips after {warmup} warmup ticks "
          f"(pace {pace_ms:.0f} ms)")
    print(f"  throughput:       {n / total_ms * 1000:7.1f} Hz")
    print(f"  min:              {samples[0]:7.2f} ms")
    print(f"  p50:              {pct(50):7.2f} ms")
    print(f"  p95:              {pct(95):7.2f} ms")
    print(f"  p99:              {pct(99):7.2f} ms")
    print(f"  max:              {samples[-1]:7.2f} ms")
    print(f"  stale frames/req: {avg_drained:7.2f}  "
          f"(0 = sync; >0 = async buffered backlog)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://localhost:8090/ws")
    ap.add_argument("-n", type=int, default=100, help="samples after warmup")
    ap.add_argument("--warmup", type=int, default=20)
    ap.add_argument("--pace-ms", type=float, default=0,
                    help="wait between samples; 0 = pipeline as fast as possible")
    args = ap.parse_args()
    asyncio.run(run(args.url, args.n, args.warmup, args.pace_ms))
