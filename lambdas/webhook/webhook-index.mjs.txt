import { createHmac } from "node:crypto";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

const client = new SecretsManagerClient();
let cached;
const SECRET_TTL_MS = 5 * 60 * 1000; // M12/T1,T6: re-fetch every 5 min
let cachedAt = 0;

async function getSecrets() {
  if (cached && Date.now() - cachedAt < SECRET_TTL_MS) return cached;
  const { SecretString } = await client.send(
    new GetSecretValueCommand({ SecretId: process.env.SECRET_NAME })
  );
  cached = JSON.parse(SecretString);
  cachedAt = Date.now();
  if (!cached.webhookUrl || !cached.webhookSecret) throw new Error("Missing required secret fields");
  return cached;
}

// M4/T3,T4: sanitize fields to mitigate prompt injection
const MAX_FIELD_LEN = 1024;
function sanitize(val, maxLen = MAX_FIELD_LEN) {
  if (typeof val !== "string") return val;
  return val.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "").slice(0, maxLen);
}

// M13/T7,T10: per-alarm dedup — skip if same alarm+state seen within window
const DEDUP_WINDOW_MS = 60_000;
const recentEvents = new Map();

function isDuplicate(alarmArn, stateValue) {
  const key = `${alarmArn}:${stateValue}`;
  const now = Date.now();
  const prev = recentEvents.get(key);
  if (prev && now - prev < DEDUP_WINDOW_MS) return true;
  recentEvents.set(key, now);
  // Prune old entries
  for (const [k, t] of recentEvents) {
    if (now - t > DEDUP_WINDOW_MS) recentEvents.delete(k);
  }
  return false;
}

export const handler = async (event) => {
  const { webhookUrl, webhookSecret } = await getSecrets();

  for (const record of event.Records) {
    let alarm;
    try {
      alarm = JSON.parse(record.Sns.Message);
    } catch (e) {
      console.error("Failed to parse SNS message:", e);
      continue;
    }
    if (!alarm.AlarmArn || !alarm.NewStateValue) {
      console.error("Invalid alarm format, skipping");
      continue;
    }
    // M13/T7,T10: skip duplicate alarm state transitions
    if (isDuplicate(alarm.AlarmArn, alarm.NewStateValue)) {
      console.log(`Dedup: skipping duplicate ${alarm.AlarmName} ${alarm.NewStateValue}`);
      continue;
    }
    const payload = {
      eventType: "incident",
      incidentId: sanitize(alarm.AlarmArn),
      action: alarm.NewStateValue === "ALARM" ? "created" : "resolved",
      priority: "HIGH",
      title: sanitize(`${alarm.AlarmName}: ${alarm.NewStateReason}`, 256),
      description: sanitize(`${alarm.AlarmDescription || ""}\n\nAlarm ARN: ${alarm.AlarmArn}`, 512),
      timestamp: record.Sns.Timestamp,
      service: alarm.Namespace ? sanitize(alarm.Namespace, 128) : undefined,
    };

    const ts = new Date().toISOString();
    const body = JSON.stringify(payload);
    const sig = createHmac("sha256", webhookSecret)
      .update(`${ts}:${body}`, "utf8")
      .digest("base64");

    try {
      const res = await fetch(webhookUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-amzn-event-timestamp": ts,
          "x-amzn-event-signature": sig,
        },
        body,
      });
      if (!res.ok) console.error(`Webhook returned ${res.status}`);
      console.log(`Alarm=${alarm.AlarmName} Action=${payload.action} Status=${res.status}`);
    } catch (e) {
      console.error(`Webhook delivery failed for ${alarm.AlarmName}:`, e);
      throw e;
    }
  }
};
