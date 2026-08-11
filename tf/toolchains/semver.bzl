"""Semver parsing, comparison and constraint solving.

Terraform's version constraint syntax over semver, implemented in pure Starlark
so a mirror entry's `~> 3.1` can be resolved against a registry's published
version list without shelling out to the tool. Depends on nothing, which is what
lets semver_test.bzl exercise it at analysis time.
"""

_DIGITS = "0123456789"

# Semver identifier characters, for prerelease and build-metadata segments.
_IDENT_CHARS = _DIGITS + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"

def _is_numeric(s):
    if s == "":
        return False
    for c in s.elems():
        if c not in _DIGITS:
            return False
    return True

def _is_dot_separated_idents(s):
    """True if s is a non-empty '.'-separated list of semver identifiers."""
    if s == "":
        return False
    for part in s.split("."):
        if part == "":
            return False
        for c in part.elems():
            if c not in _IDENT_CHARS:
                return False
    return True

def _split_version(version, min_components, max_components):
    """Splits a semver string into ([major, minor, patch], [prerelease idents]).

    Missing trailing core components are padded with zero, so a partial operand
    such as '1.2' becomes [1, 2, 0]. Build metadata is validated then dropped,
    as semver excludes it from precedence. Returns None if version does not
    parse, along with the count of core components actually written.
    """
    plus = version.split("+", 1)
    if len(plus) == 2 and not _is_dot_separated_idents(plus[1]):
        return None

    body = plus[0].split("-", 1)
    pre = []
    if len(body) == 2:
        if not _is_dot_separated_idents(body[1]):
            return None
        pre = body[1].split(".")

    written = body[0].split(".")
    if len(written) < min_components or len(written) > max_components:
        return None

    core = []
    for part in written:
        if not _is_numeric(part):
            return None
        core.append(int(part))

    given = len(core)
    for _ in range(3 - given):
        core.append(0)

    return struct(core = core, pre = pre, given = given)

def _parse_exact_version(version):
    """Parses an exact semver pin 'x.y.z[-prerelease][+build]', or returns None."""
    return _split_version(version, 3, 3)

def is_exact_version(version):
    """True if version is an exact semver pin: 'x.y.z[-prerelease][+build]'.

    Registries publish prerelease versions (e.g. 'hashicorp/aws:6.0.0-beta1'),
    which are exact pins just as much as a bare 'x.y.z' is -- the check here
    only needs to distinguish a pin from range/constraint syntax.

    Args:
      version: the version string as a mirror entry writes it.

    Returns:
      True when version parses as an exact pin.
    """
    return _parse_exact_version(version) != None

def _cmp_int(a, b):
    if a < b:
        return -1
    if a > b:
        return 1
    return 0

def _cmp_prerelease_ident(a, b):
    """Compares two prerelease identifiers; numeric ones rank below alphanumeric."""
    a_num = _is_numeric(a)
    b_num = _is_numeric(b)
    if a_num and b_num:
        return _cmp_int(int(a), int(b))
    if a_num:
        return -1
    if b_num:
        return 1
    if a < b:
        return -1
    if a > b:
        return 1
    return 0

def _cmp_version(x, y):
    """Orders two parsed versions by semver precedence."""
    for i in range(3):
        c = _cmp_int(x.core[i], y.core[i])
        if c != 0:
            return c

    # A version carrying a prerelease ranks below the same core release.
    if len(x.pre) == 0 and len(y.pre) == 0:
        return 0
    if len(x.pre) == 0:
        return 1
    if len(y.pre) == 0:
        return -1

    shared = min(len(x.pre), len(y.pre))
    for i in range(shared):
        c = _cmp_prerelease_ident(x.pre[i], y.pre[i])
        if c != 0:
            return c
    return _cmp_int(len(x.pre), len(y.pre))

# Longest first, so ">=" is not mistaken for ">".
_CONSTRAINT_OPERATORS = ["~>", ">=", "<=", "!=", "=", ">", "<"]

def parse_version_constraint(spec):
    """Parses a comma-separated version constraint into a list of terms.

    Accepts terraform's operators (`=`, `!=`, `>`, `>=`, `<`, `<=`, `~>`, and a
    bare version meaning `=`), joined by commas to mean AND.

    Args:
      spec: the constraint as written in the manifest, e.g. ">= 1.0, < 2.0".

    Returns:
      A list of (op, bound) structs, or None if any term fails to parse.
    """
    terms = []
    for raw in spec.split(","):
        term = raw.strip()
        if term == "":
            return None

        op = "="
        for candidate in _CONSTRAINT_OPERATORS:
            if term.startswith(candidate):
                op = candidate
                term = term[len(candidate):].strip()
                break

        bound = _split_version(term, 1, 3)
        if bound == None:
            return None

        terms.append(struct(op = op, bound = bound))

    if len(terms) == 0:
        return None
    return terms

def _satisfies_term(candidate, term):
    c = _cmp_version(candidate, term.bound)
    op = term.op

    if op == "=":
        return c == 0
    if op == "!=":
        return c != 0
    if op == ">":
        return c > 0
    if op == ">=":
        return c >= 0
    if op == "<":
        return c < 0
    if op == "<=":
        return c <= 0

    # "~>" pins every component to the left of the rightmost one written and
    # lets that one increment: `~> 1.0.4` is < 1.1.0, but `~> 1.1` is < 2.0.0.
    if c < 0:
        return False
    index = term.bound.given - 2
    if index < 0:
        index = 0

    upper = list(term.bound.core)
    upper[index] = upper[index] + 1
    for j in range(index + 1, 3):
        upper[j] = 0

    return _cmp_version(candidate, struct(core = upper, pre = [], given = 3)) < 0

def select_matching_version(available, spec):
    """Returns the highest published version satisfying spec, or "" if none do.

    Prereleases are never selected by a constraint, matching terraform: pin the
    exact version to mirror a prerelease.

    Args:
      available: version strings the registry publishes for one provider.
      spec: the constraint to satisfy, in `parse_version_constraint` syntax.

    Returns:
      The highest satisfying version, or "" when none match or spec is malformed.
    """
    terms = parse_version_constraint(spec)
    if terms == None:
        return ""

    best = ""
    best_parsed = None
    for version in available:
        parsed = _parse_exact_version(version)
        if parsed == None or len(parsed.pre) > 0:
            continue

        satisfied = True
        for term in terms:
            if not _satisfies_term(parsed, term):
                satisfied = False
                break
        if not satisfied:
            continue

        if best_parsed == None or _cmp_version(parsed, best_parsed) > 0:
            best = version
            best_parsed = parsed

    return best
