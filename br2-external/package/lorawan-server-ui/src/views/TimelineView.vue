<template>
  <div>
    <div class="row list-header">
      <div class="col-lg-12">
        <div class="page-header timeline-header">
          <div>
            <h1>Metrics Timeline</h1>
          </div>
          <div class="timeline-actions" role="group" aria-label="Timeline controls">
            <button
              type="button"
              class="btn btn-default"
              :class="{ active: isGroupedByDevice }"
              @click="toggleGrouping"
            >
              <span class="glyphicon glyphicon-th-list" aria-hidden="true" />
              Group by device
            </button>
            <button type="button" class="btn btn-default" @click="refreshTimeline">
              <span class="glyphicon glyphicon-refresh" aria-hidden="true" />
              Refresh
            </button>
          </div>
        </div>
      </div>
    </div>

    <div class="row list-view">
      <div class="col-lg-12">
        <div v-if="timelineError" class="alert alert-danger">
          {{ timelineError }}
        </div>
        <div class="panel panel-default">
          <div class="panel-body">
            <div ref="timelineContainer" class="metrics-timeline" />
          </div>
        </div>
      </div>
    </div>

    <div class="row list-view">
      <div class="col-lg-12">
        <div class="panel panel-default">
          <div class="panel-heading">Latest Metrics</div>
          <div class="panel-body panel-body-table">
            <div v-if="metrics.length === 0" class="text-muted timeline-empty">No metric payloads available.</div>
            <div v-else class="table-responsive">
              <table class="table table-striped table-hover">
                <thead>
                  <tr>
                    <th>Time</th>
                    <th>Device</th>
                    <th>Metric</th>
                    <th>Value</th>
                    <th>Event</th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-for="metric in latestMetrics" :key="metric.key">
                    <td>{{ formatDateTime(metric.start) }}</td>
                    <td>{{ metric.device }}</td>
                    <td>{{ metric.label }}</td>
                    <td>{{ metric.value }}</td>
                    <td>{{ metric.eventType }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import { ensureVisScript } from '../services/vis-loader';

const timelineContainer = ref(null);
const timelineError = ref('');
const isGroupedByDevice = ref(true);
const metrics = ref([]);

let timeline = null;
let items = null;
let groups = null;
let pollTimer = null;
let timelineSocket = null;
let reconnectTimer = null;
let liveMetricSequence = 0;

const POLL_INTERVAL_MS = 5000;
const TIMELINE_ZOOM_MAX_MS = 2592000000;
const TIMELINE_ZOOM_MIN_MS = 1000;
const MAX_TABLE_METRICS = 50;
const METRIC_FIELDS = [
  { key: 'battery', label: 'Battery' },
  { key: 'weight', label: 'Weight' },
  { key: 'temperature', label: 'Temperature' }
];

function parseJson(value) {
  if (!value || typeof value !== 'string') {
    return null;
  }

  try {
    return JSON.parse(value);
  } catch (_error) {
    return null;
  }
}

function decodeBase64Json(value) {
  if (!value || typeof value !== 'string') {
    return null;
  }

  try {
    const decoded = atob(value);
    if (!/^[\x09\x0A\x0D\x20-\x7E]+$/.test(decoded)) {
      return null;
    }
    return parseJson(decoded);
  } catch (_error) {
    return null;
  }
}

function asObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

function metricSource(payload) {
  const root = asObject(payload) || {};
  const nestedPayload = asObject(root.payload);
  const metricsObject = asObject(root.metrics) || asObject(nestedPayload?.metrics);
  const decodedData = decodeBase64Json(root.data) || decodeBase64Json(nestedPayload?.data);
  return {
    ...root,
    ...(nestedPayload || {}),
    ...(decodedData || {}),
    ...(metricsObject || {})
  };
}

function firstText(...values) {
  for (const value of values) {
    const text = String(value || '').trim();
    if (text) {
      return text;
    }
  }
  return '';
}

function timelineQueryParams(range) {
  return new URLSearchParams({
    start_ms: String(range.start.getTime()),
    end_ms: String(range.end.getTime()),
    timezone_offset_minutes: String(new Date().getTimezoneOffset())
  });
}

function deviceIdFor(item, payload) {
  const source = metricSource(payload);
  return firstText(
    source.device,
    source.device_id,
    source.deviceId,
    source.dev_eui,
    source.devEui,
    source.deveui,
    source.dev_addr,
    source.devAddr,
    source.devaddr,
    source.gateway_mac,
    item.eid,
    'unknown-device'
  );
}

function normalizeValue(value, field) {
  if (value === null || value === undefined || value === '') {
    return null;
  }

  const number = Number(value);
  if (Number.isFinite(number)) {
    if (field === 'battery') {
      return number > 100 ? String(Math.round(number)) : `${Math.round(number * 10) / 10}%`;
    }
    if (field === 'temperature') {
      return `${Math.round(number * 10) / 10} C`;
    }
    if (field === 'weight') {
      return `${Math.round(number * 100) / 100} kg`;
    }
  }

  return String(value);
}

function metricClass(field) {
  if (field === 'battery') {
    return 'metric-battery';
  }
  if (field === 'temperature') {
    return 'metric-temperature';
  }
  if (field === 'weight') {
    return 'metric-weight';
  }
  return '';
}

function metricsFromTimelineItem(item) {
  const payload = parseJson(item.title) || parseJson(item.args) || asObject(item.payload) || {};
  const source = metricSource(payload);
  const device = deviceIdFor(item, payload);
  const start = item.start || item.datetime || item.last_rx || new Date().toISOString();
  const eventType = item.content || item.text || item.event_type || '-';

  return METRIC_FIELDS.flatMap((definition) => {
    const value = normalizeValue(source[definition.key], definition.key);
    if (value === null) {
      return [];
    }

    return [
      {
        key: `${item.id}-${definition.key}`,
        id: `${item.id}-${definition.key}`,
        group: device,
        device,
        label: definition.label,
        field: definition.key,
        value,
        start,
        eventType,
        content: `<strong>${definition.label}</strong> ${value}`,
        title: `${device} ${definition.label}: ${value}`,
        className: metricClass(definition.key)
      }
    ];
  });
}

function timelineItemFromLiveEvent(event) {
  const receivedAt = Number(event?.received_at_ms);
  const start = Number.isFinite(receivedAt) ? new Date(receivedAt).toISOString() : new Date().toISOString();
  liveMetricSequence += 1;

  return {
    id: `live-${receivedAt || Date.now()}-${liveMetricSequence}`,
    content: event?.event_type || 'lorawan_uplink',
    start,
    title: JSON.stringify(event || {}),
    payload: event,
    eid: event?.gateway_mac || ''
  };
}

function syncTimeline(nextMetrics) {
  const nextIds = new Set(nextMetrics.map((entry) => entry.id));
  const existingIds = items.getIds();
  const removedIds = existingIds.filter((id) => !nextIds.has(id));

  if (removedIds.length > 0) {
    items.remove(removedIds);
  }

  const timelineItems = nextMetrics.map((metric) => ({
    id: metric.id,
    group: isGroupedByDevice.value ? metric.group : undefined,
    start: metric.start,
    content: metric.content,
    title: metric.title,
    className: metric.className
  }));
  items.update(timelineItems);

  const groupRows = [...new Set(nextMetrics.map((metric) => metric.group))].map((id) => ({
    id,
    content: id
  }));
  groups.clear();
  if (isGroupedByDevice.value) {
    groups.update(groupRows);
    timeline.setGroups(groups);
  } else {
    timeline.setGroups(null);
  }
}

async function fetchTimelineItems() {
  const range = timeline.getWindow();
  const params = timelineQueryParams(range);

  const response = await fetch(`/admin/timeline?${params.toString()}`, {
    credentials: 'same-origin',
    headers: { Accept: 'application/json' }
  });

  if (!response.ok) {
    throw new Error(`Timeline request failed (${response.status})`);
  }

  const payload = await response.json();
  const rawItems = Array.isArray(payload?.items) ? payload.items : [];
  const nextMetrics = rawItems.flatMap(metricsFromTimelineItem);
  metrics.value = nextMetrics.sort((left, right) => new Date(right.start) - new Date(left.start));
  syncTimeline(nextMetrics);
}

async function refreshTimeline() {
  if (!timeline) {
    return;
  }

  try {
    await fetchTimelineItems();
    timelineError.value = '';
  } catch (error) {
    timelineError.value = error instanceof Error ? error.message : 'Failed to load timeline data';
  }
}

function toggleGrouping() {
  isGroupedByDevice.value = !isGroupedByDevice.value;
  syncTimeline(metrics.value);
}

function startTimelinePolling() {
  pollTimer = window.setInterval(() => {
    void refreshTimeline();
  }, POLL_INTERVAL_MS);
}

function stopTimelinePolling() {
  if (pollTimer !== null) {
    window.clearInterval(pollTimer);
    pollTimer = null;
  }
}

function timelineWebSocketUrl() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${protocol}//${window.location.host}/admin/timeline/ws`;
}

function applyLiveTimelineEvent(event) {
  const liveMetrics = metricsFromTimelineItem(timelineItemFromLiveEvent(event));
  if (liveMetrics.length === 0) {
    return;
  }

  const nextMetrics = [...liveMetrics, ...metrics.value]
    .sort((left, right) => new Date(right.start) - new Date(left.start))
    .slice(0, MAX_TABLE_METRICS);
  metrics.value = nextMetrics;
  syncTimeline(nextMetrics);
}

function connectTimelineWebSocket() {
  if (timelineSocket || reconnectTimer !== null) {
    return;
  }

  timelineSocket = new WebSocket(timelineWebSocketUrl());
  timelineSocket.addEventListener('message', (event) => {
    const payload = parseJson(event.data);
    if (payload) {
      applyLiveTimelineEvent(payload);
    }
  });
  timelineSocket.addEventListener('open', () => {
    timelineError.value = '';
  });
  timelineSocket.addEventListener('close', () => {
    timelineSocket = null;
    reconnectTimer = window.setTimeout(() => {
      reconnectTimer = null;
      connectTimelineWebSocket();
    }, POLL_INTERVAL_MS);
  });
  timelineSocket.addEventListener('error', () => {
    timelineSocket?.close();
  });
}

function disconnectTimelineWebSocket() {
  if (reconnectTimer !== null) {
    window.clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (timelineSocket) {
    timelineSocket.close();
    timelineSocket = null;
  }
}

async function mountTimeline() {
  const vis = await ensureVisScript();

  if (!timelineContainer.value) {
    return;
  }

  items = new vis.DataSet([]);
  groups = new vis.DataSet([]);
  timeline = new vis.Timeline(timelineContainer.value, items, groups, {
    start: new Date(Date.now() - 3600000),
    end: new Date(),
    rollingMode: { follow: true, offset: 0.9 },
    selectable: false,
    height: '520px',
    stack: true,
    zoomMax: TIMELINE_ZOOM_MAX_MS,
    zoomMin: TIMELINE_ZOOM_MIN_MS
  });

  timeline.on('rangechanged', (properties) => {
    if (properties?.byUser) {
      void refreshTimeline();
    }
  });

  await refreshTimeline();
  connectTimelineWebSocket();
  startTimelinePolling();
}

function formatDateTime(value) {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return String(value || '-');
  }
  return parsed.toLocaleString();
}

const latestMetrics = computed(() => metrics.value.slice(0, MAX_TABLE_METRICS));

onMounted(async () => {
  try {
    await mountTimeline();
  } catch (error) {
    timelineError.value = error instanceof Error ? error.message : 'Failed to initialize timeline';
  }
});

onBeforeUnmount(() => {
  stopTimelinePolling();
  disconnectTimelineWebSocket();
  if (timeline) {
    timeline.destroy();
    timeline = null;
  }
  items = null;
  groups = null;
});
</script>

<style scoped>
.timeline-header {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 16px;
}

.timeline-actions {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 8px;
}

.metrics-timeline {
  min-height: 520px;
}

.timeline-empty {
  padding: 15px;
}

.panel-body-table {
  padding: 0;
}

.panel-body-table .table {
  margin-bottom: 0;
}

:deep(.metric-battery) {
  border-color: #2f7d32;
  background-color: #e7f4e4;
}

:deep(.metric-temperature) {
  border-color: #b23a48;
  background-color: #f8e3e6;
}

:deep(.metric-weight) {
  border-color: #5a6f9f;
  background-color: #e8edf8;
}

@media (max-width: 767px) {
  .timeline-header {
    align-items: stretch;
    flex-direction: column;
  }

  .timeline-actions {
    display: flex;
  }

  .timeline-actions .btn {
    flex: 1 1 auto;
  }
}
</style>
