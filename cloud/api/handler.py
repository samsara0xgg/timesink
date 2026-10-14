"""TimeSink cloud API: one Lambda behind an HTTP API whose JWT authorizer is
the Cognito user pool. The user is `claims.sub`; everything is scoped to it.

    POST   /spans    {"deviceId": str, "spans": [WireSpan]}  -> {"acked": [{"originId", "seq"}], "rejected": [...]}
    GET    /spans    ?since=<seq>|after=<seq>&deviceId=<mine> -> {"spans": [WireSpan], "cursor", "more"}
    DELETE /account                                            -> 202

A WireSpan is the client's `span` row: originId (its local rowid), start,
end, appBundleID, appName and the optional title, url, domain, document.
Pulled spans also carry deviceId and seq.

Item key is (userId, "{deviceId}#{originId:012d}") so a retried push
overwrites instead of duplicating. `seq` is assigned here at write time
(nanoseconds + random tail, fixed width so string order is time order) and
indexed by the `bySeq` GSI for pulls.

Sign-up is open, so every user is held to RATE_PER_MINUTE requests a minute
and DAILY_ITEMS pushed rows a UTC day; past either the answer is 429 with
Retry-After. The counters live in the user's own partition under keys that
start with "#" (a device id never does), expire through the table's TTL
attribute `expiresAt`, and have no `seq`, so pulls never see them.

Deleting an account can outlast one request, so DELETE /account signs every
device out, disables the user, writes the "#deleted" marker that turns away
further pushes and pulls (410: access tokens stay valid for up to an hour),
starts a delete job and answers 202. The job is this function invoked
asynchronously with {"deleteJob": {...}}: it deletes the partition page by
page, hands over to a fresh invocation of itself before it runs out of time,
and deletes the Cognito user last. The marker outlives it by MARKER_TTL.
"""

import base64
import json
import math
import os
import re
import time
import uuid
from datetime import datetime

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

# SyncEngine.pushBatch.
MAX_PUSH = 500
PAGE = 500
# Two devices pushing at the same moment can be assigned seqs in one order
# and land in the index in the other; a pull that starts from its saved
# cursor re-reads this much so nothing falls between the cracks. The client
# dedupes on (deviceId, originId).
PULL_OVERLAP_NS = 60 * 10**9
# Per-field caps in characters (Python's len, i.e. Unicode scalars, the unit
# HTTPCloud.FieldLimits cuts in). Bundle ids, app names and domains are
# short by nature; titles, URLs and document paths get room for the long
# ones. A longer value is cut rather than refused: a batch refused on every
# retry stalls that device's sync for good, and clients up to 0.3.0 cut
# every field at 4096.
LIMITS = {"appBundleID": 255, "appName": 255, "title": 1024, "url": 2048, "domain": 255, "document": 2048}
OPTIONAL = ("title", "url", "domain", "document")
REQUIRED = ("start", "end", "appBundleID", "appName")
# An ISO 8601 date-time with its offset. The client's
# ISO8601FormatStyle(includingFractionalSeconds: true) writes the
# "2026-09-22T10:00:00.000Z" form; the others are taken so a format change
# there can never have every row refused.
INSTANT = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,6})?(Z|[+-]\d\d:\d\d)")

RATE_PER_MINUTE = int(os.environ.get("RATE_PER_MINUTE", "60"))
# Several times what a heavy day records; a first upload of a long history
# spreads over a few days.
DAILY_ITEMS = int(os.environ.get("DAILY_ITEMS", "50000"))

DELETED = "#deleted"
# Longer than any access token issued before the deletion stays valid.
MARKER_TTL = 7 * 86400
DELETE_PAGE = 1000
# A delete job hands over once less than this is left of its invocation.
HANDOVER_MS = 10_000

_table = None
_cognito = None
_lambda = None
_now = time.time


class BadRequest(Exception):
    pass


class TooMany(Exception):
    def __init__(self, retry_after):
        super().__init__("too many requests")
        self.retry_after = max(1, math.ceil(retry_after))


class Gone(Exception):
    pass


def table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def cognito():
    global _cognito
    if _cognito is None:
        _cognito = boto3.client("cognito-idp")
    return _cognito


def lam():
    global _lambda
    if _lambda is None:
        _lambda = boto3.client("lambda")
    return _lambda


def handler(event, context):
    # Only an IAM principal can invoke the function directly; API Gateway's
    # events never carry this key.
    if "deleteJob" in event:
        return _delete_job(event["deleteJob"], context)
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    user_id = claims["sub"]
    route = event.get("routeKey")
    if route not in ("POST /spans", "GET /spans", "DELETE /account"):
        return _json(404, {"error": "no such route"})
    try:
        if route == "DELETE /account":
            # Repeatable: a retry after a partial failure redoes every step.
            _throttle(user_id)
            return _delete_account(user_id, claims.get("username") or claims.get("cognito:username"))
        if _deleted(user_id):
            raise Gone()
        _throttle(user_id)
        if route == "POST /spans":
            return _push(user_id, _body(event))
        return _pull(user_id, event.get("queryStringParameters") or {})
    except BadRequest as e:
        return _json(400, {"error": str(e)})
    except TooMany as e:
        resp = _json(429, {"error": str(e), "retryAfter": e.retry_after})
        resp["headers"]["Retry-After"] = str(e.retry_after)
        return resp
    except Gone:
        return _json(410, {"error": "account deleted"})


# MARK: routes


def _push(user_id, body):
    device = _device(body.get("deviceId"))
    spans = body.get("spans")
    if not isinstance(spans, list) or len(spans) > MAX_PUSH:
        raise BadRequest(f"spans must be a list of at most {MAX_PUSH}")
    items, rejected = [], []
    for raw in spans:
        item, problem = _item(user_id, device, raw)
        if problem:
            rejected.append({"originId": item["originId"], "error": problem})
        else:
            items.append(item)
    if items:
        _charge(user_id, len(items))
        t = table()
        with t.batch_writer(overwrite_by_pkeys=["userId", "sk"]) as batch:
            for item in items:
                batch.put_item(Item=item)
        # The account may have been deleted while this batch was written,
        # and its delete job may already have passed these keys. A marker
        # written after this check means the job started after these writes
        # and will find them.
        if _deleted(user_id):
            with t.batch_writer(overwrite_by_pkeys=["userId", "sk"]) as batch:
                for item in items:
                    batch.delete_item(Key={"userId": user_id, "sk": item["sk"]})
            raise Gone()
    acked = [{"originId": int(i["originId"]), "seq": i["seq"]} for i in items]
    # A row with impossible times (a clock set back, finding #12) can never
    # be stored. It is acknowledged all the same -- with a seq nothing
    # carries -- so no client, old or new, resends it forever.
    acked += [{"originId": r["originId"], "seq": _new_seq()} for r in rejected]
    return _json(200, {"acked": acked, "rejected": rejected})


def _pull(user_id, q):
    since, after = q.get("since") or "", q.get("after") or ""
    if after:
        lower = _seq_check(after)
    elif since:
        lower = f"{max(int(_seq_check(since)[:20]) - PULL_OVERLAP_NS, 0):020d}"
    else:
        lower = "0"
    mine = _device(q["deviceId"]) if q.get("deviceId") else None
    resp = table().query(
        IndexName="bySeq",
        KeyConditionExpression=Key("userId").eq(user_id) & Key("seq").gt(lower),
        Limit=PAGE,
    )
    items = resp.get("Items", [])
    more = "LastEvaluatedKey" in resp
    # The cursor is the last row read, the caller's own included. Dropping
    # them in DynamoDB (a FilterExpression) would hide how far the read got,
    # and a device alone on its account would re-read its own last page on
    # every pass.
    cursor = items[-1]["seq"] if items else (after or since or None)
    spans = [_out(i) for i in items if i["deviceId"] != mine]
    return _json(200, {"spans": spans, "cursor": cursor, "more": more})


def _delete_account(user_id, username):
    if username:
        pool = os.environ["USER_POOL_ID"]
        try:
            # Revokes every device's refresh token; the access tokens they
            # hold stay valid until they expire, hence the marker.
            cognito().admin_user_global_sign_out(UserPoolId=pool, Username=username)
            cognito().admin_disable_user(UserPoolId=pool, Username=username)
        except cognito().exceptions.UserNotFoundException:
            pass
    now = int(_now())
    table().put_item(Item={"userId": user_id, "sk": DELETED, "deletedAt": now, "expiresAt": now + MARKER_TTL})
    _invoke_self({"deleteJob": {"userId": user_id, "username": username}})
    return {"statusCode": 202}


def _delete_job(job, context):
    user_id, username = job["userId"], job.get("username")
    if not _deleted(user_id):
        return {"skipped": "no deletion marker"}
    t = table()
    query = {
        "KeyConditionExpression": Key("userId").eq(user_id),
        "ProjectionExpression": "userId, sk",
        "ConsistentRead": True,
        "Limit": DELETE_PAGE,
    }
    while True:
        resp = t.query(**query)
        with t.batch_writer() as batch:
            for it in resp.get("Items", []):
                if it["sk"] != DELETED:
                    batch.delete_item(Key={"userId": it["userId"], "sk": it["sk"]})
        if "LastEvaluatedKey" not in resp:
            break
        query["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        if context.get_remaining_time_in_millis() < HANDOVER_MS:
            # A fresh invocation starts from the top: what is deleted is gone.
            _invoke_self({"deleteJob": job})
            return {"handedOver": True}
    if username:
        try:
            cognito().admin_delete_user(UserPoolId=os.environ["USER_POOL_ID"], Username=username)
        except cognito().exceptions.UserNotFoundException:
            pass
    return {"done": True}


# MARK: limits


def _throttle(user_id):
    """Counts one request in the user's current minute; 429 past the limit."""
    now = _now()
    window = int(now // 60)
    try:
        table().update_item(
            Key={"userId": user_id, "sk": f"#rate#{window}"},
            UpdateExpression="ADD #n :one SET expiresAt = :expires",
            ConditionExpression="attribute_not_exists(#n) OR #n < :limit",
            ExpressionAttributeNames={"#n": "n"},
            ExpressionAttributeValues={":one": 1, ":limit": RATE_PER_MINUTE, ":expires": (window + 2) * 60},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        raise TooMany((window + 1) * 60 - now) from e


def _charge(user_id, count):
    """Counts `count` rows against the user's UTC day; 429 (until midnight)
    if they would go past the cap. A batch is taken whole or not at all."""
    now = _now()
    day = int(now // 86400)
    if count > DAILY_ITEMS:
        raise TooMany((day + 1) * 86400 - now)
    try:
        table().update_item(
            Key={"userId": user_id, "sk": f"#day#{day}"},
            UpdateExpression="ADD #n :count SET expiresAt = :expires",
            ConditionExpression="attribute_not_exists(#n) OR #n <= :room",
            ExpressionAttributeNames={"#n": "n"},
            ExpressionAttributeValues={":count": count, ":room": DAILY_ITEMS - count, ":expires": (day + 2) * 86400},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        raise TooMany((day + 1) * 86400 - now) from e


def _deleted(user_id):
    resp = table().get_item(Key={"userId": user_id, "sk": DELETED}, ConsistentRead=True, ProjectionExpression="sk")
    return "Item" in resp


def _invoke_self(payload):
    lam().invoke(
        FunctionName=os.environ["AWS_LAMBDA_FUNCTION_NAME"],
        InvocationType="Event",
        Payload=json.dumps(payload).encode(),
    )


# MARK: shapes


def _item(user_id, device, raw):
    """The item for one pushed row, and why its times make it unstorable
    (None when they are fine). A malformed row is a 400."""
    if not isinstance(raw, dict):
        raise BadRequest("span must be an object")
    origin = raw.get("originId")
    if not isinstance(origin, int) or isinstance(origin, bool) or origin < 0 or origin >= 10**12:
        raise BadRequest("originId must be a non-negative integer")
    item = {
        "userId": user_id,
        "sk": f"{device}#{origin:012d}",
        "seq": _new_seq(),
        "deviceId": device,
        "originId": origin,
    }
    for k in REQUIRED:
        item[k] = _text(raw.get(k), k, required=True)
    for k in OPTIONAL:
        v = _text(raw.get(k), k, required=False)
        if v is not None:
            item[k] = v
    start, end = _instant(item["start"]), _instant(item["end"])
    if start is None or end is None:
        return item, "start and end must be ISO 8601 times with an offset"
    if start > end:
        return item, "start is after end"
    return item, None


def _instant(v):
    if not INSTANT.fullmatch(v):
        return None
    try:
        return datetime.fromisoformat(v[:-1] + "+00:00" if v.endswith("Z") else v)
    except ValueError:  # a well-formed impossible date, such as month 13
        return None


def _out(item):
    out = {"originId": int(item["originId"]), "deviceId": item["deviceId"], "seq": item["seq"]}
    for k in REQUIRED + OPTIONAL:
        if k in item:
            out[k] = item[k]
    return out


def _new_seq():
    return f"{time.time_ns():020d}{uuid.uuid4().hex[:6]}"


def _seq_check(s):
    if not (20 <= len(s) <= 26) or not s[:20].isdigit():
        raise BadRequest("bad cursor")
    return s


def _device(v):
    if not isinstance(v, str) or not (8 <= len(v) <= 64) or not all(c.isalnum() or c == "-" for c in v):
        raise BadRequest("deviceId must be 8-64 alphanumeric characters")
    return v


def _text(v, name, required):
    if v is None:
        if required:
            raise BadRequest(f"{name} is required")
        return None
    if not isinstance(v, str):
        raise BadRequest(f"{name} must be a string")
    limit = LIMITS.get(name)
    return v[:limit] if limit else v


def _body(event):
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        body = json.loads(raw)
    except ValueError as e:
        raise BadRequest(f"body is not JSON: {e}") from e
    if not isinstance(body, dict):
        raise BadRequest("body must be an object")
    return body


def _json(status, body):
    return {"statusCode": status, "headers": {"Content-Type": "application/json"}, "body": json.dumps(body)}
