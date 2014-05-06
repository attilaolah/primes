# Attila's Primes [![wercker status](https://app.wercker.com/status/81bf2e1abe235c766b0e09a5e3c87c0d/s/ "wercker status")](https://app.wercker.com/project/bykey/81bf2e1abe235c766b0e09a5e3c87c0d)

> My personal collection of prime numbers, just for fun.

This repo contains a random collection of [Pratt][2] [primality
certificates][1].

### Certificate format

They are JSON-encoded in a simple format. The following is an example of a
valid certificate for 1021:

```json
[[1021, 10,
  17,
  5,
  3,
  [2, 2]],
 [17, 3,
  [2, 4]],
 [5, 2,
  [2, 2]],
 [3, 2,
  2]]
```

A valid certificate is a list of certificate parts. Each part in itself is also
a list, containing at least three elements:

1. the prime
2. the witness
3. one or more factors

Each factor can be either a number, or a list of two numbers, in which case the
second number is the exponent.

Every factor of every part of the chain must also have its own certificate,
except for the number 2, which we believe to be prime without checking.

The above example could be written in plain text, like this:

```
1021 = 17·5·3·2²+1, witness = 10;
  17 = 2⁴+1,        witness =  3;
   5 = 2²+1,        witness =  2;
   3 = 2+1,         witness =  2;
   2 is prime.
```

### PRs are welcome!

Pull requests are welcome, as long as they add a new prime that doesn't break
the tests. How you found the prime does not matter.

[1]: //en.wikipedia.org/wiki/Primality_certificate
[2]: //en.wikipedia.org/wiki/Primality_certificate#Pratt_certificates
