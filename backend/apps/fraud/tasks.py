from celery import shared_task

from .services import sync_suspected_fraud_findings


@shared_task(
    bind=True,
    name="fraud.sync_suspected_fraud_findings",
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_jitter=True,
    retry_kwargs={"max_retries": 3},
)
def sync_suspected_fraud_findings_task(self):
    result = sync_suspected_fraud_findings()
    return {
        "active": result.active,
        "generated": result.generated,
        "resolved": result.resolved,
    }

