from celery import shared_task

from .discovery import run_discovery_scan


@shared_task(name="price_checker.scan_network")
def scan_network() -> dict:
    """Scan the LAN for price-checker devices and register them.

    Callable on demand or from a Celery beat schedule for periodic plug-and-play
    discovery.
    """
    return run_discovery_scan()
