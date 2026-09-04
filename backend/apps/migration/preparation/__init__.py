"""Turning an uploaded file into something a connector can read.

The migration feature's input used to be a database server; it is now a file the
shop hands over. Everything between "these bytes arrived" and "this is a Fahd
database with 34,112 products in it" lives here:

* :mod:`identify` — what kind of file is this, really (by header, not extension)
* :mod:`access` — Microsoft Access → SQLite, table by table, with progress
* :mod:`fahd_reconstruct` — Fahd's invoices, replayed out of its audit log
* :mod:`detect` — which connector wrote this
* :mod:`analyze` — how much of what is inside
* :mod:`stages` — how a twenty-minute job says what it is doing
* :mod:`pipeline` — the order all of that runs in
"""
