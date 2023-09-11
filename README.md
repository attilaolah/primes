# `primes`

This repo contains a single prime number and its [Pratt certificate][2]. The
prime is JSON-encoded in the file `PRIME.json`. Previous primes can be found in
the git history.


## Pratt Certificates

Pratt certificates are JSON-encoded and pretty-printed. The following is an
example of a valid certificate for 1021, compacted for readability.

```json
[
  [1021, 10, 17, 5, 3, [2, 2]],
  [17, 3, [2, 4]],
  [5, 2, [2, 2]],
  [3, 2, 2]
]
```

A valid certificate is an array of certificate parts. Each part is itself also
an array, containing at least three elements:

1. the prime
2. the witness
3. one or more factors

In the above example, the first certificate part is `[1021, 10, 17, 5, 3, [2,
2]]`. `1021` is the prime, `10` is the witness, the rest are the factors.

Each factor can be either a number, or a list of two numbers, in which case the
second number is the exponent. In the first part of the above example, `17`,
`5` and `3` are simple factors, and `[2, 2]` is a factor representing 2².

Every factor of every part of the chain must also have its own certificate,
except for the number 2, which is a known prime.

The above example could be written in plain text, like this:

```
1021 (witness: 10) = 17·5·3·2²+1;
  17 (witness:  3) = 2⁴+1;
   5 (witness:  2) = 2²+1;
   3 (witness:  2) = 2+1;
   2 is prime.
```


## Pull Requests

Pull requests changing the prime number to a bigger one are welcome.


## Tests

A quick check of the certificate format can be done by running `python test.py
< PRIME.json`. To run a full test (which is way slower than the short check),
run `python test.py --verify < PRIME.json`.

Note that Python 3 will run the tests somewhat faster than Python 2.

[1]: //en.wikipedia.org/wiki/Primality_certificate
[2]: //en.wikipedia.org/wiki/Primality_certificate#Pratt_certificates
