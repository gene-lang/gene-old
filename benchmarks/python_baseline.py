import json
import time

WARMUP_ROUNDS = 2
MEASURE_ROUNDS = 5


def best_ms(fn):
  for _ in range(WARMUP_ROUNDS):
    fn()
  best = float("inf")
  for _ in range(MEASURE_ROUNDS):
    t0 = time.perf_counter()
    fn()
    elapsed = (time.perf_counter() - t0) * 1000.0
    if elapsed < best:
      best = elapsed
  return best


def bench_fib():
  def fib(n):
    if n <= 1:
      return n
    return fib(n - 1) + fib(n - 2)

  out = 0
  for _ in range(200):
    out = fib(20)
  return out


def bench_array():
  arr = []
  for _ in range(40000):
    arr.append(1)
  total = 0
  for x in arr:
    total += x
  return total


def bench_dispatch():
  class Counter:
    def __init__(self, base):
      self.base = base

    def bump(self, x):
      return self.base + x

  c = Counter(1)
  out = 0
  for _ in range(200000):
    out = c.bump(1)
  return out


if __name__ == "__main__":
  result = {
    "fib": best_ms(bench_fib),
    "array": best_ms(bench_array),
    "dispatch": best_ms(bench_dispatch),
  }
  print(json.dumps(result))
