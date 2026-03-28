# `primes`

This repo stores Pratt certificates for primes in `data/`, with one certificate
per file.


## Certificate Format

Certificates are plain text files with canonical line format:

```text
V 1
P <prime>
W <witness>
F <factor>
F <factor>^<exponent>
...
```

Rules:

1. Exactly one `P` and one `W` line.
2. At least one `F` line.
3. Decimal integers only (canonical form, no leading zeroes).
4. Factors must be strictly ascending by factor base.
5. File must end with a trailing newline.

Each file name is a lowercase hex prefix (min length 16) of:

`sha256(<prime-in-base-10>)`

`TIP` contains the file id of the current top prime certificate.


## Pull Requests

Pull requests changing the prime number to a bigger one are welcome.


## Verify

Verify the certificate pointed to by `TIP`:

`nix run .#verify`

Verify a specific certificate id:

`nix run .#verify -- <id>`

Verify a specific file path:

`nix run .#verify -- data/<id>`

What verification checks:

1. Certificate format and canonical constraints.
2. File id matches `sha256(prime)` prefix.
3. Direct dependency presence in `data/` for every factor prime except `2`.
4. Full Pratt math validation for the selected certificate.

[1]: //en.wikipedia.org/wiki/Primality_certificate
[2]: //en.wikipedia.org/wiki/Primality_certificate#Pratt_certificates
