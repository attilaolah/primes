# Attila's Primes [![wercker status](https://app.wercker.com/status/81bf2e1abe235c766b0e09a5e3c87c0d/s/ "wercker status")](https://app.wercker.com/project/bykey/81bf2e1abe235c766b0e09a5e3c87c0d)

> My personal collection of prime numbers. Just for fun.

### Pratt Certificates

This repo contains a collection of JSON-encoded [Pratt][2] [certificates][1].

The format of the certificates is compact so that we don't use too much of the
space that is freely provided to us by GitHub.

The following is an example of a valid certificate for 1021:

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
1021 (witness: 10) = 17·5·3·2²+1;
  17 (witness:  3) = 2⁴+1;
   5 (witness:  2) = 2²+1;
   3 (witness:  2) = 2+1;
   2 is prime.
```

### Pull Requests, Please!

Pull requests are always welcome, as long as:

* they add at least one new prime,
* they don't break the tests, and
* the primes are bigger than the smallest one we have.

I absolutely don't care how you've found the prime, but you're welcome to share
that in another repo.


[1]: //en.wikipedia.org/wiki/Primality_certificate
[2]: //en.wikipedia.org/wiki/Primality_certificate#Pratt_certificates
