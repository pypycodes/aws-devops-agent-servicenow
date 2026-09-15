const MAX_FIELD_LENGTH = 4000;

function sanitize(value, maxLength = MAX_FIELD_LENGTH) {
  if (typeof value !== "string") return "";
  return value.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "").slice(0, maxLength);
}

function present(value) {
  return typeof value === "string" && value !== "" && value !== "null" && value !== "undefined";
}

function messageFromRecord(record) {
  const message = JSON.parse(record.Sns.Message);
  if (!message.AlarmArn || !message.NewStateValue) {
    return message;
  }
  return message;
}

async function getAccessToken() {
  const credentials = `${process.env.SERVICENOW_CLIENT_ID}:${process.env.SERVICENOW_CLIENT_SECRET}`;
  const response = await fetch(`${process.env.SERVICENOW_INSTANCE_URL.replace(/\/$/, "")}/oauth_token.do`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(credentials).toString("base64")}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  if (!response.ok) throw new Error(`ServiceNow OAuth returned ${response.status}`);
  const body = await response.json();
  if (!body.access_token) throw new Error("ServiceNow OAuth response did not contain an access token");
  return body.access_token;
}

async function serviceNowRequest(path, token, options = {}) {
  const response = await fetch(`${process.env.SERVICENOW_INSTANCE_URL.replace(/\/$/, "")}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
  });
  if (!response.ok) throw new Error(`ServiceNow API returned ${response.status}`);
  return response.json();
}

async function findIncident(token, correlationId) {
  const query = encodeURIComponent(`correlation_id=${correlationId}`);
  const response = await serviceNowRequest(
    `/api/now/table/incident?sysparm_query=${query}&sysparm_limit=1&sysparm_fields=sys_id,number`,
    token,
  );
  return response.result?.[0];
}

async function updateIncident(token, incident, message) {
  const notes = [
    `AWS DevOps Agent event: ${message.eventType || "unknown"}`,
    `Status: ${message.status || "unknown"}`,
    `Priority: ${message.priority || "unknown"}`,
    `Task ID: ${message.taskId || "unknown"}`,
    `Summary record ID: ${message.summaryId || "unknown"}`,
    `Updated at: ${message.updatedAt || "unknown"}`,
  ].join("\n");
  await serviceNowRequest(`/api/now/table/incident/${incident.sys_id}`, token, {
    method: "PATCH",
    body: JSON.stringify({ work_notes: sanitize(notes) }),
  });
  console.log(`Updated ServiceNow incident ${incident.number} from ${message.eventType}`);
}

export const handler = async (event) => {
  const token = await getAccessToken();

  for (const record of event.Records || []) {
    const message = messageFromRecord(record);
    if (!message.AlarmArn) {
      const lifecycleData = message.detail?.data || {};
      const lifecycleMetadata = message.detail?.metadata || {};
      const correlationId = [
        message.alarmArn,
        message.incidentId,
        message.correlationId,
        lifecycleData.alarm_arn,
        lifecycleData.incident_id,
        lifecycleData.correlation_id,
        lifecycleMetadata.alarm_arn,
        lifecycleMetadata.incident_id,
        lifecycleMetadata.correlation_id,
      ].find(present);
      if (!present(correlationId)) {
        console.error("Lifecycle event has no alarm or correlation ID; cannot map to a ServiceNow incident");
        continue;
      }
      const incident = await findIncident(token, correlationId);
      if (!incident) {
        console.error(`No ServiceNow incident found for correlation ID ${correlationId}`);
        continue;
      }
      await updateIncident(token, incident, message);
      continue;
    }

    const alarm = message;
    if (alarm.NewStateValue !== "ALARM") {
      console.log(`Skipping ${alarm.AlarmName || alarm.AlarmArn}: state=${alarm.NewStateValue}`);
      continue;
    }

    const encodedArn = encodeURIComponent(alarm.AlarmArn);
    const existing = await serviceNowRequest(
      `/api/now/table/incident?sysparm_query=correlation_id=${encodedArn}&sysparm_limit=1&sysparm_fields=sys_id,number`,
      token,
    );
    if (existing.result?.length) {
      console.log(`Incident already exists for ${alarm.AlarmArn}: ${existing.result[0].number}`);
      continue;
    }

    const incident = await serviceNowRequest("/api/now/table/incident", token, {
      method: "POST",
      body: JSON.stringify({
        short_description: sanitize(`AWS alarm: ${alarm.AlarmName || alarm.AlarmArn}`, 160),
        description: sanitize([
          alarm.AlarmDescription,
          alarm.NewStateReason,
          `Alarm ARN: ${alarm.AlarmArn}`,
          `State: ${alarm.NewStateValue}`,
          `Region: ${alarm.Region || record.Sns.TopicArn || "unknown"}`,
        ].filter(Boolean).join("\n\n")),
        correlation_id: sanitize(alarm.AlarmArn, 255),
        category: "software",
        impact: "2",
        urgency: "2",
      }),
    });
    console.log(`Created ServiceNow incident ${incident.result?.number || "unknown"} for ${alarm.AlarmArn}`);
  }
};
