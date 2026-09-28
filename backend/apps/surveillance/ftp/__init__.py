"""The FTP server recorders upload their footage to.

See SURVEILLANCE_FTP_PLAN.md. Runs as its own process (``manage.py
run_ftp_server``, the ``ftp`` role of the backend image), because an FTP server
is a long-lived listener with its own port range and nothing in a web worker's
lifecycle suits it.
"""
