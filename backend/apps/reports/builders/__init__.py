"""One module per subject area; ``apps.reports.registry`` maps reports to them.

Split out of a single 1,300-line ``services.py`` when the catalogue grew from
nine reports to nineteen. The split is by *subject* rather than by report, so
the two reports that answer one question — receivables aging and the customer
statement it summarises — share their definition of a balance instead of each
carrying a copy.
"""
