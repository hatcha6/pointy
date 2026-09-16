"""Test runner that stops a SQLite run from passing for a Postgres one.

``backend/.env`` is untracked, so a ``git worktree`` never has one, and the
``.env.example`` that ``make backend-env`` copies in its place points at
``sqlite:///db.sqlite3``. Both ways in — ``manage.py test`` directly, or
``make backend-test`` — therefore run a worktree's suite on SQLite while the
primary checkout runs it on Postgres, and nothing in the output says so:
at default verbosity Django prints the same bare
``Creating test database for alias 'default'...`` either way.

That would be harmless if the two engines ran the same tests. They do not.
Eight modules gate themselves on ``connection.vendor == "postgresql"`` and
*skip* — including the query-scaling guards that exist precisely to prove a
performance fix — and the trigram index migrations no-op, so the schema is not
even the same. The run comes back green having never executed the tests that
prove the change, which is the worst possible failure: silent, and in the
direction that says "yes".

So: say which engine is in use, loudly, every run; and let a caller that
requires Postgres say so and get an error instead of a false pass.

    POINTY_REQUIRE_POSTGRES=1 python manage.py test apps.sales
"""

import os
import sys

from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.db import connections
from django.test.runner import DiscoverRunner

#: Set truthy to turn "this is not Postgres" from a warning into a hard error.
REQUIRE_POSTGRES_ENV = "POINTY_REQUIRE_POSTGRES"

#: Password hashing during tests.
#:
#: PBKDF2 is deliberately expensive — that is the whole point of it — and at
#: Django's default work factor one ``create_user(password=...)`` costs about
#: **100 ms** on this hardware. There are 238 such call sites in this suite and
#: most of them sit in a ``setUp`` that runs once per test method, so the suite
#: spends minutes computing hashes that no assertion ever looks at.
#:
#: MD5 is catastrophic for storing a real password and perfect for this: the
#: tests care whether ``check_password`` says yes, not how long it took to find
#: out. Nothing in the suite asserts on an algorithm — only on
#: ``check_password`` — which is what makes this safe to do globally.
#:
#: It goes **first**, not instead: the real hashers stay in the list so any
#: password already hashed with one still verifies.
FAST_PASSWORD_HASHER = "django.contrib.auth.hashers.MD5PasswordHasher"

_TRUTHY = {"1", "true", "yes", "on"}

_REMEDY = (
    "Run against Postgres instead:\n"
    "    DATABASE_URL='postgres://postgres:postgres@127.0.0.1:5432/pointy' \\\n"
    "        python manage.py test <labels>\n"
    "or copy the primary checkout's env into this tree:\n"
    "    cp /path/to/pointy/backend/.env backend/.env\n"
    "(`make postgres` first if the container is not up.)"
)


def require_postgres_requested(environ=None):
    """Whether the caller declared this run has to be on Postgres."""
    environ = os.environ if environ is None else environ
    return str(environ.get(REQUIRE_POSTGRES_ENV, "")).strip().lower() in _TRUTHY


def postgres_requirement_error(vendor, *, required):
    """The message for a run that demanded Postgres and did not get it.

    ``None`` when the run is acceptable — either it is on Postgres, or nobody
    asked for it.
    """
    if not required or vendor == "postgresql":
        return None
    return (
        f"{REQUIRE_POSTGRES_ENV} is set, but the test database engine is "
        f"'{vendor}'. Postgres-only tests would silently skip and this run "
        f"would report success without proving anything.\n\n{_REMEDY}"
    )


def describe_test_database(vendor, name):
    """The one-line banner naming the engine every run is actually using."""
    return f"[pointy] test database: {vendor} '{name}'"


def sqlite_warning(vendor, skipped_count=None):
    """The warning shown when a run that could have been Postgres was not.

    ``None`` on Postgres. ``skipped_count`` is folded in when the run is over
    and the number of skips is known.
    """
    if vendor == "postgresql":
        return None
    tail = ""
    if skipped_count:
        tail = (
            f"\n{skipped_count} test(s) were SKIPPED, which on this engine "
            "includes every Postgres-only guard."
        )
    return (
        f"WARNING: running on '{vendor}', not Postgres. Postgres-only tests "
        f"(query-scaling guards, PgBouncer settings, dead-connection recovery, "
        f"trigram search) skip silently, so a green run here does NOT mean the "
        f"change is proven.{tail}\n\n{_REMEDY}"
    )


def _emit(message):
    print(message, file=sys.stderr, flush=True)


def fast_password_hashers(configured):
    """``configured`` with the cheap hasher in front, unless it already is.

    Idempotent because ``setup_test_environment`` is not guaranteed to run
    exactly once — ``--parallel`` sets each worker up in its own process, and a
    caller driving the runner by hand may set up twice.
    """
    configured = list(configured)
    if configured and configured[0] == FAST_PASSWORD_HASHER:
        return configured
    return [FAST_PASSWORD_HASHER] + [
        hasher for hasher in configured if hasher != FAST_PASSWORD_HASHER
    ]


class PointyTestRunner(DiscoverRunner):
    """``DiscoverRunner`` that names its database and can insist on Postgres."""

    def setup_test_environment(self, **kwargs):
        super().setup_test_environment(**kwargs)
        self._real_password_hashers = settings.PASSWORD_HASHERS
        settings.PASSWORD_HASHERS = fast_password_hashers(
            settings.PASSWORD_HASHERS
        )

    def teardown_test_environment(self, **kwargs):
        # Restored rather than left changed: a caller that drives the runner
        # in-process — the upgrade rehearsal harness does — must not inherit a
        # settings module that hashes passwords with MD5 afterwards.
        hashers = getattr(self, "_real_password_hashers", None)
        if hashers is not None:
            settings.PASSWORD_HASHERS = hashers
        super().teardown_test_environment(**kwargs)

    def setup_databases(self, **kwargs):
        result = super().setup_databases(**kwargs)
        connection = connections["default"]
        self._vendor = connection.vendor
        _emit(
            describe_test_database(
                self._vendor, connection.settings_dict.get("NAME", "?")
            )
        )
        error = postgres_requirement_error(
            self._vendor, required=require_postgres_requested()
        )
        if error is not None:
            # Tear the database back down before bailing out, so a refused run
            # does not leave a stray test database behind for the next one.
            self.teardown_databases(result)
            raise ImproperlyConfigured(error)
        warning = sqlite_warning(self._vendor)
        if warning is not None:
            _emit(warning)
        return result

    def suite_result(self, suite, result, **kwargs):
        # Repeat the warning after the results, where it cannot scroll away
        # above a wall of test output, now that the skip count is known.
        warning = sqlite_warning(
            getattr(self, "_vendor", "unknown"), len(getattr(result, "skipped", ()))
        )
        if warning is not None:
            _emit(warning)
        return super().suite_result(suite, result, **kwargs)
