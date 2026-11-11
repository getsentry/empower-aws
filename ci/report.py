"""Send a CI run's result and log tail to Sentry (sentry-developer-experience/ci-aws).

Lets people without GitHub access read CI output through Sentry.
Usage: python3 ci/report.py <task> <exit_code> <log_file>
"""
import json, os, sys, time, urllib.request, uuid

DSN_KEY = "5ec7d1d74026836da662f11cb31943b1"
HOST = "o4509446862274560.ingest.us.sentry.io"
PROJECT_ID = "4512404756299776"

task, code, log_file = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(log_file, errors="replace") as f:
    log = f.read()
event_id = uuid.uuid4().hex
run_url = "{}/{}/actions/runs/{}".format(
    os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
    os.environ.get("GITHUB_REPOSITORY", ""),
    os.environ.get("GITHUB_RUN_ID", ""),
)
event = {
    "event_id": event_id,
    "timestamp": time.time(),
    "platform": "other",
    "level": "info" if code == 0 else "error",
    "logger": "ci",
    "message": {"formatted": f"CI task {task} {'passed' if code == 0 else f'failed (exit {code})'}"},
    "fingerprint": ["ci", task, "ok" if code == 0 else "failed"],
    "release": os.environ.get("GITHUB_SHA"),
    "tags": {"task": task, "exit_code": str(code), "run_id": os.environ.get("GITHUB_RUN_ID", "")},
    "extra": {"run_url": run_url},
}
# Key facts a task wants surfaced as tags, written as key=value lines (e.g. url=...).
summary_file = os.environ.get("CI_SUMMARY", "/tmp/ci-summary")
if os.path.exists(summary_file):
    for line in open(summary_file):
        key, _, value = line.strip().partition("=")
        if key and value:
            event["tags"][key] = value[:200]
# The log goes as an attachment: Sentry's data scrubbing replaced it with [Filtered]
# when it was sent as event data.
attachment = log.encode("utf-8", "replace")[-500_000:]
body = b"\n".join([
    json.dumps({"event_id": event_id, "dsn": f"https://{DSN_KEY}@{HOST}/{PROJECT_ID}"}).encode(),
    json.dumps({"type": "event"}).encode(),
    json.dumps(event).encode(),
    json.dumps({"type": "attachment", "length": len(attachment), "filename": f"ci-{task}.log",
                "content_type": "text/plain"}).encode(),
    attachment,
])
req = urllib.request.Request(
    f"https://{HOST}/api/{PROJECT_ID}/envelope/",
    data=body,
    headers={
        "Content-Type": "application/x-sentry-envelope",
        "X-Sentry-Auth": f"Sentry sentry_version=7, sentry_key={DSN_KEY}, sentry_client=empower-aws-ci/1.0",
    },
)
try:
    urllib.request.urlopen(req, timeout=15).read()
    print(f"Reported {task} to Sentry ci-aws (event {event_id})")
except Exception as e:  # reporting must never fail the build
    print(f"Could not report to Sentry: {e}")
