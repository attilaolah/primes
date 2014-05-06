"""Verify Pratt certificates."""
import json
import os

from fractions import gcd


DB = 'pratt'


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
        assert gcd(self.prime, self.witness) == 1
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


def load_file(filename):
    """JSON-decode a certificate from a filename."""
    with open(os.path.join(DB, filename)) as src:
        return _Pratt(json.load(src))


def test_all():
    """Test every certificate."""
    for cert in os.listdir(DB):
        load_file(cert).verify()


if __name__ == '__main__':
    test_all()
