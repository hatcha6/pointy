import hashlib
import json
import re
from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

from django.db import transaction
from django.db.models import F
from django.http import QueryDict
from django.utils import timezone
from rest_framework.exceptions import APIException, ValidationError
from rest_framework.response import Response

from .db_locks import bounded_lock_wait
from .models import IdempotencyRecord


IDEMPOTENCY_HEADER = "Idempotency-Key"
IDEMPOTENCY_REPLAYED_HEADER = "Idempotency-Replayed"
MAX_IDEMPOTENCY_KEY_LENGTH = 180
IDEMPOTENCY_KEY_PATTERN = re.compile(r"^[A-Za-z0-9:_./=-]+$")


class IdempotencyConflict(APIException):
    status_code = 409
    default_detail = "Idempotency key was already used with a different request."
    default_code = "idempotency_conflict"


class IdempotencyInProgress(APIException):
    status_code = 409
    default_detail = "Idempotent request has not completed yet."
    default_code = "idempotency_in_progress"


def run_idempotent_request(request, handler):
    key = idempotency_key(request)
    if not key:
        return handler()

    validate_idempotency_key(key)
    lookup = {
        "owner_key": idempotency_owner_key(request),
        "method": request.method.upper(),
        "path": request.path_info,
        "key": key,
    }
    request_hash = idempotency_request_hash(request)

    with transaction.atomic():
        # This transaction is the shop's money path: the locks taken below and
        # inside ``handler()`` (stock rows, the order, the register session) are
        # the ones a cashier waits on. Bound the wait so a stuck holder fails the
        # request in seconds instead of hanging it past the client's own
        # deadline, where "did the sale go through?" has no answer.
        with bounded_lock_wait():
            record, created = IdempotencyRecord.objects.select_for_update().get_or_create(
                **lookup,
                defaults={"request_hash": request_hash},
            )
            if not created:
                if record.request_hash != request_hash:
                    raise IdempotencyConflict()
                if record.response_status_code is None:
                    raise IdempotencyInProgress()
                IdempotencyRecord.objects.filter(pk=record.pk).update(
                    replay_count=F("replay_count") + 1,
                    updated_at=timezone.now(),
                )
                response = Response(
                    record.response_data,
                    status=record.response_status_code,
                )
                response[IDEMPOTENCY_REPLAYED_HEADER] = "true"
                return response

            response = handler()
            if 200 <= response.status_code < 300:
                record.response_status_code = response.status_code
                record.response_data = normalize_json_value(
                    getattr(response, "data", None)
                )
                record.completed_at = timezone.now()
                record.save(
                    update_fields=[
                        "response_status_code",
                        "response_data",
                        "completed_at",
                        "updated_at",
                    ]
                )
                response[IDEMPOTENCY_REPLAYED_HEADER] = "false"
            else:
                record.delete()
            return response


def idempotency_key(request):
    return request.headers.get(IDEMPOTENCY_HEADER, "").strip()


def validate_idempotency_key(key):
    if len(key) > MAX_IDEMPOTENCY_KEY_LENGTH:
        raise ValidationError(
            {"idempotency_key": "Idempotency key is too long."}
        )
    if not IDEMPOTENCY_KEY_PATTERN.match(key):
        raise ValidationError(
            {"idempotency_key": "Idempotency key contains unsupported characters."}
        )


def idempotency_owner_key(request):
    user = getattr(request, "user", None)
    if user is not None and user.is_authenticated:
        return f"user:{user.pk}"
    return "anonymous"


def idempotency_request_hash(request):
    payload = {
        "body": normalize_json_value(request.data),
        "query": normalize_json_value(request.query_params),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def normalize_json_value(value):
    if isinstance(value, QueryDict):
        return {
            key: normalize_json_value(values if len(values) > 1 else values[0])
            for key, values in sorted(value.lists())
        }
    if isinstance(value, dict):
        return {
            str(key): normalize_json_value(value[key])
            for key in sorted(value.keys(), key=str)
        }
    if isinstance(value, (list, tuple)):
        return [normalize_json_value(item) for item in value]
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, UUID):
        return str(value)
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    return str(value)
