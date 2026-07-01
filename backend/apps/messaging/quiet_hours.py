"""Shop-local quiet-hours window for a gateway.

Marketing messages are held until the window opens; transactional messages
(invoice, debt, OTP) ignore quiet hours. Times are stored as shop-local
``TimeField``s and compared in Africa/Tripoli (plan R9).
"""

from __future__ import annotations

from datetime import datetime

from django.utils import timezone

from apps.core.timeutils import business_timezone


def in_quiet_hours(gateway, moment: datetime | None = None) -> bool:
    start = gateway.quiet_hours_start
    end = gateway.quiet_hours_end
    if not start or not end or start == end:
        return False
    local_time = (moment or timezone.now()).astimezone(business_timezone()).time()
    if start < end:
        return start <= local_time < end
    # Window spans midnight (e.g. 22:00 → 08:00).
    return local_time >= start or local_time < end
