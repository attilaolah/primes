# Candidate filtering benchmark

Measured on this checkout on 2026-09-11 with a 100,000,000 sieve limit and
`factor = 2 * 3 * 5 * 7`.  The timer encloses only residue filtering after the
prime sieve and divisor list have been constructed.

| implementation | time |
| --- | ---: |
| prior Python reference (`_filter_python`) | 8.339 s |
| native `candidate_filter` | 2.514 s |

The native helper receives `factor % r` for every divisor, so it never
truncates an arbitrarily large Python factor; a zero remainder correctly skips
that divisor.  Very large base factors still incur Python big-integer remainder
preparation time, and that cost is separate from the timing above.

This does not make a 5-billion limit practical by itself: the byte sieve,
prime/candidate Python lists, deterministic shuffle, and persisted ordered
plan all have substantial memory, allocation, and I/O costs.
