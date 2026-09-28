"""Footage kept on this server, from recorders that upload it over FTP.

See SURVEILLANCE_FTP_PLAN.md. ``ingest`` decides what an upload is and what to
keep of it, ``housekeeping`` holds the archive to its retention and its share
of the disk, and ``playback`` serves it back in the same MJPEG the recorders'
own footage arrives in.
"""
