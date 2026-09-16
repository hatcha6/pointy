"""Guards the test runner that stops a SQLite run passing for a Postgres one.

The failure this prevents is not hypothetical: a scratch ``git worktree`` has no
``backend/.env`` (it is untracked) and ``.env.example`` points at sqlite, so both
``manage.py test`` and ``make backend-test`` run a worktree on sqlite. The
Postgres-only suites then *skip* rather than fail, and the run reports success
having proved nothing — which has already produced a confidently wrong review
verdict. These tests pin the two behaviours that make that impossible to miss:
the engine is always named, and a caller can demand Postgres and get an error.
"""

from django.conf import settings
from django.test import SimpleTestCase

from apps.core.test_runner import (
    FAST_PASSWORD_HASHER,
    REQUIRE_POSTGRES_ENV,
    describe_test_database,
    fast_password_hashers,
    postgres_requirement_error,
    require_postgres_requested,
    sqlite_warning,
)


class TestRunnerWiringTests(SimpleTestCase):
    def test_the_project_uses_the_pointy_runner(self):
        # Without this the banner and the guard never run at all.
        self.assertEqual(settings.TEST_RUNNER, "apps.core.test_runner.PointyTestRunner")


class RequirePostgresFlagTests(SimpleTestCase):
    def test_unset_does_not_require_postgres(self):
        self.assertFalse(require_postgres_requested({}))

    def test_truthy_spellings_all_request_it(self):
        for value in ("1", "true", "TRUE", "yes", "on", " 1 "):
            with self.subTest(value=value):
                self.assertTrue(
                    require_postgres_requested({REQUIRE_POSTGRES_ENV: value})
                )

    def test_falsy_spellings_do_not(self):
        for value in ("", "0", "false", "no", "off"):
            with self.subTest(value=value):
                self.assertFalse(
                    require_postgres_requested({REQUIRE_POSTGRES_ENV: value})
                )


class PostgresRequirementErrorTests(SimpleTestCase):
    def test_no_error_when_nobody_asked(self):
        self.assertIsNone(postgres_requirement_error("sqlite", required=False))

    def test_no_error_on_postgres_even_when_required(self):
        self.assertIsNone(postgres_requirement_error("postgresql", required=True))

    def test_error_names_the_engine_and_the_remedy(self):
        error = postgres_requirement_error("sqlite", required=True)
        self.assertIsNotNone(error)
        self.assertIn("sqlite", error)
        self.assertIn(REQUIRE_POSTGRES_ENV, error)
        # The message has to carry the fix, or it just tells someone they are
        # stuck. Both escape hatches are named.
        self.assertIn("DATABASE_URL", error)
        self.assertIn("cp ", error)


class SqliteWarningTests(SimpleTestCase):
    def test_postgres_runs_are_not_warned_about(self):
        self.assertIsNone(sqlite_warning("postgresql"))
        self.assertIsNone(sqlite_warning("postgresql", 12))

    def test_sqlite_run_is_warned_about_even_with_no_skips(self):
        warning = sqlite_warning("sqlite")
        self.assertIsNotNone(warning)
        self.assertIn("sqlite", warning)
        # The point of the warning is that green does not mean proven.
        self.assertIn("does NOT mean", warning)

    def test_skip_count_is_folded_in_when_known(self):
        self.assertIn("7 test(s) were SKIPPED", sqlite_warning("sqlite", 7))

    def test_zero_skips_does_not_claim_skips(self):
        self.assertNotIn("SKIPPED", sqlite_warning("sqlite", 0))


class DescribeTestDatabaseTests(SimpleTestCase):
    def test_banner_names_engine_and_database(self):
        # Django's own line is identical for sqlite and Postgres at default
        # verbosity, which is exactly why this one exists.
        banner = describe_test_database("postgresql", "test_pointy")
        self.assertIn("postgresql", banner)
        self.assertIn("test_pointy", banner)


class FastPasswordHashingTests(SimpleTestCase):
    """The cheap hasher the runner installs for the duration of a run.

    PBKDF2 is meant to be slow, and at Django's work factor one
    ``create_user(password=...)`` costs about 100 ms. There are 238 of those
    call sites in this suite and most sit in a ``setUp``, so the default
    settings spend minutes on hashes no assertion ever reads — `apps.employees`
    alone went from 11.5s to 1.1s.
    """

    def test_the_cheap_hasher_is_installed_while_the_suite_runs(self):
        # Asserted against live settings rather than the helper: the point is
        # that the runner actually applied it, not that it could have.
        self.assertEqual(settings.PASSWORD_HASHERS[0], FAST_PASSWORD_HASHER)

    def test_the_real_hashers_are_kept_so_stored_passwords_still_verify(self):
        """Prepended, never substituted. A password already hashed with PBKDF2 —
        a fixture, a dump restored into a test — has to keep verifying."""
        hashers = fast_password_hashers(
            ["django.contrib.auth.hashers.PBKDF2PasswordHasher"]
        )
        self.assertEqual(hashers[0], FAST_PASSWORD_HASHER)
        self.assertIn("django.contrib.auth.hashers.PBKDF2PasswordHasher", hashers)

    def test_applying_it_twice_does_not_stack_it(self):
        """``--parallel`` sets each worker up in its own process, and a caller
        driving the runner by hand may set up twice."""
        once = fast_password_hashers(["django.contrib.auth.hashers.PBKDF2PasswordHasher"])
        self.assertEqual(fast_password_hashers(once), once)

    def test_a_password_set_under_it_still_checks_out(self):
        from django.contrib.auth.hashers import check_password, make_password

        encoded = make_password("pass1234")
        self.assertTrue(check_password("pass1234", encoded))
        self.assertFalse(check_password("wrong", encoded))
