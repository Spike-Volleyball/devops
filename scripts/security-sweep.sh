#!/bin/bash
# Suspicious-activity sweep — follow-up to the 2026-08-17 bot incident.
# Runs read-only checks against the service DBs and edge/auth logs; emails
# denys.bielov@gmail.com via SES only when something trips. Cron-installed on
# the prod box (hourly). `--test` forces an email to prove the pipe works.
set -uo pipefail

BASE=/opt/volleyspike
ALERT_TO="denys.bielov@gmail.com"
ALERT_FROM="Spike Security <noreply@volleyspike.app>"
PG="docker exec volleyspike-postgres-1 psql -U volleyer_user -qAt"
FINDINGS=""

add_finding() {
    FINDINGS="${FINDINGS}
== $1
$2"
}

sql() { $PG -d "$1" -c "$2" 2>/dev/null; }

# 1. Signup burst: more than 5 accounts inside one hour
burst=$(sql auth "SELECT count(*) FROM \"Users\" WHERE \"CreatedAt\" > now() - interval '1 hour'")
if [ "${burst:-0}" -gt 5 ]; then
    rows=$(sql auth "SELECT \"Email\" || ' verified=' || \"IsEmailVerified\" FROM \"Users\" WHERE \"CreatedAt\" > now() - interval '1 hour' ORDER BY \"CreatedAt\"")
    add_finding "SIGNUP BURST: $burst accounts in the last hour" "$rows"
fi

# 2. Bot-pattern signups in the last 24h (the 08-17 actors used agent* and numeric addresses)
patt=$(sql auth "SELECT \"Email\" || ' created=' || \"CreatedAt\"::text FROM \"Users\" WHERE \"CreatedAt\" > now() - interval '24 hours' AND (lower(\"Email\") LIKE 'agent%' OR \"Email\" ~ '^[0-9]+@' OR \"Email\" ~ '@[0-9]+\.')")
[ -n "$patt" ] && add_finding "BOT-PATTERN SIGNUPS (24h)" "$patt"

# 3. Conversation fan-out: someone opened 4+ new direct/group chats in 24h
#    (the in-app cap is 5/day for young accounts — this fires one step earlier)
fanout=$(sql messages "SELECT coalesce(up.\"Email\", c.\"CreatedBy\"::text) || ': ' || count(*) || ' new chats' FROM \"Chats\" c LEFT JOIN \"UserProfiles\" up ON up.\"Id\" = c.\"CreatedBy\" WHERE c.\"CreatedAt\" > now() - interval '24 hours' AND c.\"Type\" IN (0,1) AND c.\"CreatedBy\" IS NOT NULL GROUP BY 1 HAVING count(*) >= 4")
[ -n "$fanout" ] && add_finding "CHAT FAN-OUT (24h)" "$fanout"

# 4. Young account (<48h) sending a message spree (>30 msgs in 24h)
spree=$(sql messages "SELECT up.\"Email\" || ': ' || count(*) || ' msgs (account ' || date_trunc('hour', now() - up.\"CreatedAt\") || ' old)' FROM \"Messages\" m JOIN \"UserProfiles\" up ON up.\"Id\" = m.\"SenderId\" WHERE m.\"SentAt\" > now() - interval '24 hours' AND up.\"CreatedAt\" > now() - interval '48 hours' GROUP BY up.\"Email\", up.\"CreatedAt\" HAVING count(*) > 30")
[ -n "$spree" ] && add_finding "YOUNG-ACCOUNT MESSAGE SPREE (24h)" "$spree"

# 5. User reports — the MessageReports table has no other reader
reports=$(sql messages "SELECT 'chat=' || \"ChatId\" || ' msg=' || \"MessageId\" || ' reason: ' || left(\"Reason\", 120) FROM \"MessageReports\" WHERE \"CreatedAt\" > now() - interval '25 hours'")
[ -n "$reports" ] && add_finding "NEW MESSAGE REPORTS (25h) — someone asked for help" "$reports"

# 6. Auth abuse signals from the last ~65 minutes of service logs
authlog=$(docker logs volleyspike-auth-service-1 --since 65m 2>&1)
hp=$(echo "$authlog" | grep -c "honeypot tripped")
ts=$(echo "$authlog" | grep -c "Turnstile verification rejected")
rl=$(echo "$authlog" | grep -c '"Status":429')
nv=$(echo "$authlog" | grep -c "EMAIL_NOT_VERIFIED")
if [ "$hp" -gt 0 ] || [ "$ts" -gt 0 ] || [ "$rl" -gt 3 ] || [ "$nv" -gt 10 ]; then
    add_finding "AUTH ABUSE SIGNALS (last hour)" "honeypot trips: $hp | turnstile rejections: $ts | rate-limit 429s: $rl | unverified-login failures: $nv"
fi

# 7. Edge: one IP hammering auth endpoints (>100 auth POSTs in the last hour)
CADDY_LOG=$(docker inspect volleyspike-caddy-1 --format '{{range .Mounts}}{{if eq .Destination "/var/log/caddy"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)/access-api.log
if [ -f "$CADDY_LOG" ]; then
    hot=$(tail -n 50000 "$CADDY_LOG" | python3 -c '
import sys, json, time, collections
cutoff = time.time() - 3600
hits = collections.Counter()
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get("ts", 0) < cutoff: continue
        req = e.get("request", {})
        if req.get("method") == "POST" and req.get("uri", "").startswith("/auth/"):
            hits[e.get("request", {}).get("client_ip", "?")] += 1
    except Exception: pass
for ip, n in hits.most_common(3):
    if n > 100: print(f"{ip}: {n} auth POSTs")
')
    [ -n "$hot" ] && add_finding "EDGE: IP HAMMERING /auth/* (1h)" "$hot"
fi

if [ "${1:-}" = "--test" ]; then
    add_finding "TEST" "security-sweep --test invoked; the alert pipe works."
fi

if [ -n "$FINDINGS" ]; then
    AK=$(grep -oP '(?<=^AWS_ACCESS_KEY_ID=).*' "$BASE/.env.common")
    SK=$(grep -oP '(?<=^AWS_SECRET_ACCESS_KEY=).*' "$BASE/.env.common")
    RG=$(grep -oP '(?<=^AWS_REGION=).*' "$BASE/.env.common")
    BODY="Spike security sweep on $(hostname) at $(date -u +%FT%TZ)
$FINDINGS

Runbook: memory project_bot_incident_2026_08_17 / Linear SPI-5988."
    REQ=$(mktemp /tmp/security-sweep-mail.XXXXXX.json)
    BODY="$BODY" FROM="$ALERT_FROM" TO="$ALERT_TO" python3 - > "$REQ" <<'PYEOF'
import json, os
print(json.dumps({
    "FromEmailAddress": os.environ["FROM"],
    "Destination": {"ToAddresses": [os.environ["TO"]]},
    "Content": {"Simple": {
        "Subject": {"Data": "Spike security sweep: findings"},
        "Body": {"Text": {"Data": os.environ["BODY"]}}}}
}))
PYEOF
    docker run --rm -v "$REQ":/req.json:ro \
        -e AWS_ACCESS_KEY_ID="$AK" -e AWS_SECRET_ACCESS_KEY="$SK" \
        -e AWS_DEFAULT_REGION="${RG:-eu-west-2}" amazon/aws-cli \
        sesv2 send-email --cli-input-json file:///req.json >/dev/null 2>&1 \
        && mailed=yes || mailed=FAILED
    rm -f "$REQ"
else
    mailed=n/a
fi

echo "$(date -u +%FT%TZ) sweep done findings=$([ -n "$FINDINGS" ] && echo YES || echo none) mail=$mailed"
