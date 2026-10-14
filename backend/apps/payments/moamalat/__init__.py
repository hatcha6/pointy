"""Live card verification against the shop's own Moamalat merchant account.

The terminal's processor keeps a list of every card transaction it took
(``/transformerch``). With a live portal token the backend reads that list and
matches each card payment to the transaction that proves it — while the
checkout is still open when a till is watching, otherwise on a quiet tick.

The token is the hard part: a ~15-minute sliding session, no refresh, an OTP on
every login. ``custody`` keeps it warm (with the relay as a second, independent
holder), ``matching`` reads and matches, ``watch`` runs the fast loop while a
checkout is open. Verification never blocks a sale: an unmatched payment is
*pending verification* and is swept again until it matches.

Design: ``tools/moamalat-capture/TOKEN_CUSTODY_DESIGN.md``. API shapes:
``tools/moamalat-capture/API_CONTRACT.md``.
"""
