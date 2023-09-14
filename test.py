"""Verify a single Pratt certificate."""
import json
import math
import sys


class _Single(tuple):
    """Pratt single certificate."""

    def verify(self):
        """Verify a single part."""
        prime = 1
        assert len(self) > 2
        assert isinstance(self.prime, int)
        assert isinstance(self.witness, int)
        assert self.prime > 2
        assert self.witness > 1
        assert math.gcd(self.prime, self.witness) == 1
        for factor in self.factors:
            if isinstance(factor, int):
                prime *= factor
                continue
            assert isinstance(factor, list)
            assert len(factor) == 2
            factor, exp = factor
            assert factor > 1
            assert exp > 1
            prime *= factor**exp
        assert self.prime == prime+1
        output('#')
        assert pow(self.witness, prime, self.prime) == 1
        if '--verify' in sys.argv:
            for factor in self.factors:
                if isinstance(factor, list):
                    factor = factor[0]
                assert pow(self.witness, prime//factor, self.prime) != 1
                output('+')
        print()

    @property
    def prime(self):
        """Prime."""
        return self[0]

    @property
    def witness(self):
        """Witness."""
        return self[1]

    @property
    def factors(self):
        """Prime factors."""
        return self[2:]


class _Pratt(list):
    """Full Pratt certificate (including all parts)."""

    def __init__(self, parts):
        super(_Pratt, self).__init__(parts)
        for i, part in enumerate(self):
            self[i] = _Single(part)

    def verify(self):
        """Verify a collection of certificates."""
        primes = set()
        assert len(self) > 0
        # First pass: verify all parts
        for part in self:
            part.verify()
            assert part.prime not in primes
            primes.add(part.prime)
        # Second pass: make sure no parts are missing
        for part in self:
            for factor in part.factors:
                if not isinstance(factor, int):
                    factor = factor[0]
                if factor != 2:
                    assert factor in primes


def output(text):
    """Print without a buffer."""
    sys.stdout.write(text)
    sys.stdout.flush()


if __name__ == '__main__':
    sys.set_int_max_str_digits(10000)
    _Pratt(json.load(sys.stdin)).verify()
