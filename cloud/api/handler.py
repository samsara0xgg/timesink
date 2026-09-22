"""TimeSink cloud API: one Lambda behind an HTTP API whose JWT authorizer is
the Cognito user pool. The user is `claims.sub`; everything is scoped to it.

    POST   /spans    {"deviceId": str, "spans": [WireSpan]}  -> {"acked": [{"originId", "seq"}]}
    GET    /spans    ?since=<seq>|after=<seq>&deviceId=<mine> -> {"spans": [WireSpan], "cursor", "more"}
    DELETE /account                                            -> 204

A WireSpan is the client's `span` row: originId (its local rowid), start,
end, appBundleID, appName and the optional title, url, domain, document.
Pulled spans also carry deviceId and seq.

Item key is (userId, "{deviceId}#{originId:012d}") so a retried push
overwrites instead of duplicating. `seq` is assigned here at write time
(nanoseconds + random tail, fixed width so string order is time order) and
indexed by the `bySeq` GSI for pulls.
"""

import base64
import json
import os
import time
import uuid

import boto3
from boto3.dynamodb.conditions import Attr, Key

MAX_PUSH = 1000
PAGE = 500
# Two devices pushing at the same moment can be assigned seqs in one order
# and land in the index in the other; a pull that starts from its saved
# cursor re-reads this much so nothing falls between the cracks. The client
# dedupes on (deviceId, originId).
PULL_OVERLAP_NS = 60 * 10**9
MAX_LEN = 4096
OPTIONAL = ("title", "url", "domain", "document")
REQUIRED = ("start", "end", "appBundleID", "appName")

_table = None
_cognito = None


class BadRequest(Exception):
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


def handler(event, _context):
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    user_id = claims["sub"]
    route = event.get("routeKey")
    try:
        if route == "POST /spans":
            return _push(user_id, _body(event))
        if route == "GET /spans":
            return _pull(user_id, event.get("queryStringParameters") or {})
        if route == "DELETE /account":
            return _delete_account(user_id, claims.get("username") or claims.get("cognito:username"))
        return _json(404, {"error": "no such route"})
    except BadRequest as e:
        return _json(400, {"error": str(e)})


# MARK: routes


def _push(user_id, body):
    device = _device(body.get("deviceId"))
    spans = body.get("spans")
    if not isinstance(spans, list) or len(spans) > MAX_PUSH:
        raise BadRequest(f"spans must be a list of at most {MAX_PUSH}")
    items = [_item(user_id, device, raw) for raw in spans]
    with table().batch_writer(overwrite_by_pkeys=["userId", "sk"]) as batch:
        for item in items:
            batch.put_item(Item=item)
    return _json(200, {"acked": [{"originId": int(i["originId"]), "seq": i["seq"]} for i in items]})


def _pull(user_id, q):
    since, after = q.get("since") or "", q.get("after") or ""
    if after:
        lower = _seq_check(after)
    elif since:
        lower = f"{max(int(_seq_check(since)[:20]) - PULL_OVERLAP_NS, 0):020d}"
    else:
        lower = "0"
    kwargs = {
        "IndexName": "bySeq",
        "KeyConditionExpression": Key("userId").eq(user_id) & Key("seq").gt(lower),
        "Limit": PAGE,
    }
    if q.get("deviceId"):
        kwargs["FilterExpression"] = Attr("deviceId").ne(_device(q["deviceId"]))
    resp = table().query(**kwargs)
    items = resp.get("Items", [])
    more = "LastEvaluatedKey" in resp
    if more:
        cursor = resp["LastEvaluatedKey"]["seq"]
    elif items:
        cursor = items[-1]["seq"]
    else:
        cursor = after or since or None
    return _json(200, {"spans": [_out(i) for i in items], "cursor": cursor, "more": more})


def _delete_account(user_id, username):
    t = table()
    query = {"KeyConditionExpression": Key("userId").eq(user_id), "ProjectionExpression": "userId, sk"}
    resp = t.query(**query)
    with t.batch_writer() as batch:
        while True:
            for it in resp.get("Items", []):
                batch.delete_item(Key={"userId": it["userId"], "sk": it["sk"]})
            if "LastEvaluatedKey" not in resp:
                break
            resp = t.query(ExclusiveStartKey=resp["LastEvaluatedKey"], **query)
    if username:
        try:
            cognito().admin_delete_user(UserPoolId=os.environ["USER_POOL_ID"], Username=username)
        except cognito().exceptions.UserNotFoundException:
            pass
    return {"statusCode": 204}


# MARK: shapes


def _item(user_id, device, raw):
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
    return item


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
    if not isinstance(v, str) or len(v) > MAX_LEN:
        raise BadRequest(f"{name} must be a string of at most {MAX_LEN} characters")
    return v


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
