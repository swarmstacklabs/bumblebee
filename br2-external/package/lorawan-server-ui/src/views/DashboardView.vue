<template>
  <div>
    <div class="row list-header">
      <div class="col-lg-12">
        <div class="page-header">
          <h1>Dashboard</h1>
        </div>
      </div>
    </div>

    <div class="row lit-view">
      <div class="col-lg-12">
        <div v-if="timelineError" class="alert alert-danger">
          {{ timelineError }}
        </div>
        <div class="panel panel-default">
          <div ref="timelineContainer" class="dashboard-timeline" />
        </div>
      </div>
    </div>

    <div class="row list-view">
      <div class="col-lg-6">
        <div class="panel panel-default">
          <div class="panel-heading">
            <RouterLink to="/servers/list">Servers</RouterLink>
          </div>
          <div class="panel-body panel-body-table">
            <div v-if="serversStore.error" class="alert alert-danger">
              {{ serversStore.error }}
            </div>
            <div v-else-if="serversStore.loading" class="text-muted">Loading servers...</div>
            <div v-else-if="servers.length === 0" class="text-muted">No servers available.</div>
            <div v-else class="table-responsive">
              <table class="table table-striped table-hover">
                <thead>
                  <tr>
                    <th>
                      <button type="button" class="sortable-column" @click="changeServersSort('sname')">
                        <span class="sortable-label sortable-label-min">Server Name</span>
                        <span class="glyphicon" :class="serversSortIcon('sname')" aria-hidden="true" />
                      </button>
                    </th>
                    <th>
                      <button
                        type="button"
                        class="sortable-column"
                        @click="changeServersSort('modules')"
                      >
                        <span class="sortable-label sortable-label-medium">Version</span>
                        <span
                          class="glyphicon"
                          :class="serversSortIcon('modules')"
                          aria-hidden="true"
                        />
                      </button>
                    </th>
                    <th>
                      <button
                        type="button"
                        class="sortable-column"
                        @click="changeServersSort('memory')"
                      >
                        <span class="sortable-label sortable-label-medium">Memory</span>
                        <span
                          class="glyphicon"
                          :class="serversSortIcon('memory')"
                          aria-hidden="true"
                        />
                      </button>
                    </th>
                    <th>
                      <button
                        type="button"
                        class="sortable-column"
                        @click="changeServersSort('disk')"
                      >
                        <span class="sortable-label sortable-label-min">Disk</span>
                        <span
                          class="glyphicon"
                          :class="serversSortIcon('disk')"
                          aria-hidden="true"
                        />
                      </button>
                    </th>
                    <th>
                      <button
                        type="button"
                        class="sortable-column"
                        @click="changeServersSort('health_decay')"
                      >
                        <span class="sortable-label sortable-label-medium">Status</span>
                        <span
                          class="glyphicon"
                          :class="serversSortIcon('health_decay')"
                          aria-hidden="true"
                        />
                      </button>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-for="(server, index) in servers" :key="server.sname || `server-${index}`">
                    <td>{{ server.sname || '-' }}</td>
                    <td>{{ getServerVersion(server) }}</td>
                    <td>{{ formatMemory(server.memory) }}</td>
                    <td>{{ formatDisk(server.disk) }}</td>
                    <td>
                      <span class="server-status" :class="serverStatusClass(server)">
                        <span class="glyphicon" :class="serverStatusIcon(server)" aria-hidden="true" />
                        <span>{{ serverStatusLabel(server) }}</span>
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
      <div class="col-lg-6">
        
      </div>
    </div>

    <div class="row list-view">
      <div class="col-lg-6">
        <div class="panel panel-default">
          <div class="panel-heading">
            <RouterLink to="/events/list">Events</RouterLink>
          </div>
          <div class="panel-body panel-body-table">
            <div v-if="eventsStore.error" class="alert alert-danger">
              {{ eventsStore.error }}
            </div>
            <div v-else-if="eventsStore.loading" class="text-muted">Loading events...</div>
            <div v-else-if="recentEvents.length === 0" class="text-muted">No events available.</div>
            <div v-else class="table-responsive">
              <table class="table table-striped table-hover">
                <thead>
                  <tr>
                    <th>
                      <button
                        type="button"
                        class="sortable-column"
                        @click="changeEventsSort('last_rx')"
                      >
                        <span class="sortable-label sortable-label-min">Last Occurred</span>
                        <span class="glyphicon" :class="sortIcon('last_rx')" aria-hidden="true" />
                      </button>
                    </th>
                    <th>
                      <button
                        type="button"
                        class="sortable-column"
                        @click="changeEventsSort('entity')"
                      >
                        <span class="sortable-label sortable-label-medium">Entity</span>
                        <span class="glyphicon" :class="sortIcon('entity')" aria-hidden="true" />
                      </button>
                    </th>
                    <th>
                      <button type="button" class="sortable-column" @click="changeEventsSort('eid')">
                        <span class="sortable-label sortable-label-medium">Eid</span>
                        <span class="glyphicon" :class="sortIcon('eid')" aria-hidden="true" />
                      </button>
                    </th>
                    <th>
                      <button type="button" class="sortable-column" @click="changeEventsSort('text')">
                        <span class="sortable-label sortable-label-medium">Text</span>
                        <span class="glyphicon" :class="sortIcon('text')" aria-hidden="true" />
                      </button>
                    </th>
                    <th>
                      <button type="button" class="sortable-column" @click="changeEventsSort('args')">
                        <span class="sortable-label sortable-label-medium">Args</span>
                        <span class="glyphicon" :class="sortIcon('args')" aria-hidden="true" />
                      </button>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-for="(eventRow, index) in recentEvents" :key="eventRow.evid || `event-${index}`">
                    <td>{{ formatDateTime(eventRow.last_rx) }}</td>
                    <td>{{ eventRow.entity || '-' }}</td>
                    <td>
                      <RouterLink
                        v-if="eventRow.eid"
                        :to="`/servers/edit/${encodeURIComponent(serverEditId(eventRow))}`"
                      >
                        {{ eventRow.eid }}
                      </RouterLink>
                      <span v-else>-</span>
                    </td>
                    <td>{{ eventRow.text || '-' }}</td>
                    <td>{{ formatEventArgs(eventRow.args) }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
      <div class="col-lg-6">
        <div class="panel panel-default">
          <div class="panel-heading">Recent Frames</div>
          <div class="panel-body">
            <div class="placeholder-box">Frames list placeholder</div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import { RouterLink } from 'vue-router';
import { ensureVisScript } from '../services/vis-loader';
import { useEventsStore } from '../stores/events';
import { useServersStore } from '../stores/servers';

const timelineContainer = ref(null);
const timelineError = ref('');
const serversStore = useServersStore();
const eventsStore = useEventsStore();
const MAX_DASHBOARD_EVENTS = 7;
const serversSortField = ref('sname');
const serversSortDir = ref('ASC');
const eventsSortField = ref('last_rx');
const eventsSortDir = ref('DESC');

const toFiniteNumber = (value) => {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
};

const formatBytes = (bytes) => {
  const value = toFiniteNumber(bytes);
  if (value === null || value < 0) {
    return '-';
  }
  if (value === 0) {
    return '0 Bytes';
  }

  const units = ['Bytes', 'KB', 'MB', 'GB', 'TB', 'PB'];
  const exponent = Math.min(units.length - 1, Math.floor(Math.log(value) / Math.log(1024)));
  const scaled = value / 1024 ** exponent;
  const rounded = scaled >= 10 ? Math.round(scaled) : Math.round(scaled * 10) / 10;
  return `${rounded} ${units[exponent]}`;
};

const getServerVersion = (server) =>
  server?.modules?.bumblebee || server?.modules?.['bumblebee'] || '-';

const formatMemory = (memory) => {
  if (!memory || typeof memory !== 'object') {
    return '-';
  }

  const freeMemory = toFiniteNumber(memory.free_memory) || 0;
  const bufferedMemory = toFiniteNumber(memory.buffered_memory) || 0;
  const cachedMemory = toFiniteNumber(memory.cached_memory) || 0;
  const totalMemory = toFiniteNumber(memory.total_memory);

  const free = freeMemory + bufferedMemory + cachedMemory;
  if (totalMemory && totalMemory > 0) {
    const freePercent = Math.max(0, Math.min(100, (100 * free) / totalMemory));
    return `${formatBytes(free)} (${Math.round(freePercent)}%)`;
  }

  return free > 0 ? formatBytes(free) : '-';
};

const formatDisk = (disks) => {
  if (!Array.isArray(disks) || disks.length === 0) {
    return '-';
  }

  const rootDisk = disks.find((disk) => disk?.id === '/') || disks[0];
  const sizeKb = toFiniteNumber(rootDisk?.size_kb);
  const percentUsed = toFiniteNumber(rootDisk?.percent_used);
  if (sizeKb === null || percentUsed === null) {
    return '-';
  }

  const freePercent = Math.max(0, Math.min(100, 100 - percentUsed));
  const freeBytes = sizeKb * 1024 * (freePercent / 100);
  return `${formatBytes(freeBytes)} (${Math.round(freePercent)}%)`;
};

const getHealthDecay = (server) => toFiniteNumber(server?.health_decay);

const serverStatus = (server) => {
  const decay = getHealthDecay(server);
  const alerts = Array.isArray(server?.health_alerts) ? server.health_alerts : [];

  if (decay === null && alerts.length === 0) {
    return 'unknown';
  }
  if (decay !== null && decay > 50) {
    return 'critical';
  }
  if ((decay !== null && decay > 0) || alerts.length > 0) {
    return 'warning';
  }
  return 'online';
};

const serverStatusLabel = (server) => {
  const status = serverStatus(server);
  if (status === 'critical') {
    return 'Critical';
  }
  if (status === 'warning') {
    return 'Warning';
  }
  if (status === 'online') {
    return 'Online';
  }
  return 'Unknown';
};

const serverStatusIcon = (server) => {
  const status = serverStatus(server);
  if (status === 'critical') {
    return 'glyphicon-remove-sign';
  }
  if (status === 'warning') {
    return 'glyphicon-warning-sign';
  }
  if (status === 'online') {
    return 'glyphicon-ok-sign';
  }
  return 'glyphicon-question-sign';
};

const serverStatusClass = (server) => {
  const status = serverStatus(server);
  if (status === 'critical') {
    return 'text-danger';
  }
  if (status === 'warning') {
    return 'text-warning';
  }
  if (status === 'online') {
    return 'text-success';
  }
  return 'text-muted';
};

const servers = computed(() => serversStore.servers);
const recentEvents = computed(() => eventsStore.events.slice(0, MAX_DASHBOARD_EVENTS));

const loadServers = async () =>
  serversStore.fetchServers({
    sortField: serversSortField.value,
    sortDir: serversSortDir.value
  });

const loadEvents = async () =>
  eventsStore.fetchEvents({
    page: 1,
    perPage: MAX_DASHBOARD_EVENTS,
    sortField: eventsSortField.value,
    sortDir: eventsSortDir.value
  });

const changeServersSort = async (column) => {
  if (serversSortField.value === column) {
    serversSortDir.value = serversSortDir.value === 'ASC' ? 'DESC' : 'ASC';
  } else {
    serversSortField.value = column;
    serversSortDir.value = 'ASC';
  }

  try {
    await loadServers();
  } catch (_error) {
    // Error is reflected via serversStore.error.
  }
};

const changeEventsSort = async (column) => {
  if (eventsSortField.value === column) {
    eventsSortDir.value = eventsSortDir.value === 'ASC' ? 'DESC' : 'ASC';
  } else {
    eventsSortField.value = column;
    eventsSortDir.value = 'ASC';
  }

  try {
    await loadEvents();
  } catch (_error) {
    // Error is reflected via eventsStore.error.
  }
};

const sortIcon = (column) => {
  if (eventsSortField.value !== column) {
    return 'glyphicon-sort';
  }
  return eventsSortDir.value === 'ASC' ? 'glyphicon-sort-by-attributes' : 'glyphicon-sort-by-attributes-alt';
};

const serversSortIcon = (column) => {
  if (serversSortField.value !== column) {
    return 'glyphicon-sort';
  }
  return serversSortDir.value === 'ASC' ? 'glyphicon-sort-by-attributes' : 'glyphicon-sort-by-attributes-alt';
};

const formatDateTime = (value) => {
  const text = String(value || '').trim();
  if (!text) {
    return '-';
  }

  const parsed = new Date(text);
  if (Number.isNaN(parsed.getTime())) {
    return text;
  }

  return parsed.toLocaleString();
};

const formatEventArgs = (value) => {
  if (value === null || value === undefined || value === '') {
    return '-';
  }
  if (typeof value === 'object') {
    return JSON.stringify(value);
  }
  return String(value);
};

const decodeHex = (value) => {
  const text = String(value || '').trim();
  if (!text || text.length % 2 !== 0 || !/^[0-9a-fA-F]+$/.test(text)) {
    return '';
  }

  const bytes = new Uint8Array(text.length / 2);
  for (let index = 0; index < text.length; index += 2) {
    bytes[index / 2] = Number.parseInt(text.slice(index, index + 2), 16);
  }

  const decoded = new TextDecoder().decode(bytes).replace(/\0+$/g, '');
  return /^[\x20-\x7E]+$/.test(decoded) ? decoded : '';
};

const serverEditId = (eventRow) => {
  const rawEid = String(eventRow?.eid || '').trim();
  if (!rawEid) {
    return '';
  }

  const decoded = decodeHex(rawEid);
  return decoded || rawEid;
};

let timeline = null;
let items = null;
let pollTimer = null;

const POLL_INTERVAL_MS = 5000;
const TIMELINE_ZOOM_MAX_MS = 2592000000;
const TIMELINE_ZOOM_MIN_MS = 1000;

const timelineQueryParams = (range) => new URLSearchParams({
  start_ms: String(range.start.getTime()),
  end_ms: String(range.end.getTime()),
  timezone_offset_minutes: String(new Date().getTimezoneOffset())
});

const syncTimelineItems = (nextItems) => {
  const nextIds = new Set(nextItems.map((entry) => entry.id));
  const existingIds = items.getIds();
  const removedIds = existingIds.filter((id) => !nextIds.has(id));

  if (removedIds.length > 0) {
    items.remove(removedIds);
  }
  items.update(nextItems);
};

const fetchTimelineItems = async () => {
  if (!timeline) {
    return;
  }

  const range = timeline.getWindow();
  const params = timelineQueryParams(range);

  const response = await fetch(`/admin/timeline?${params.toString()}`);
  if (!response.ok) {
    throw new Error(`Timeline request failed (${response.status})`);
  }

  const contentType = response.headers.get('content-type') || '';
  if (!contentType.includes('application/json')) {
    throw new Error('Timeline request returned a non-JSON response');
  }

  const payload = await response.json();
  const nextItems = Array.isArray(payload?.items) ? payload.items : [];
  syncTimelineItems(nextItems);
};

const refreshTimeline = async () => {
  try {
    await fetchTimelineItems();
    timelineError.value = '';
  } catch (error) {
    timelineError.value = error instanceof Error ? error.message : 'Failed to load timeline data';
  }
};

const startTimelinePolling = () => {
  pollTimer = window.setInterval(() => {
    void refreshTimeline();
  }, POLL_INTERVAL_MS);
};

const stopTimelinePolling = () => {
  if (pollTimer !== null) {
    window.clearInterval(pollTimer);
    pollTimer = null;
  }
};

const mountTimeline = async () => {
  const vis = await ensureVisScript();

  if (!timelineContainer.value) {
    return;
  }

  items = new vis.DataSet([]);
  timeline = new vis.Timeline(timelineContainer.value, items, {
    start: new Date(Date.now() - 600000),
    end: new Date(),
    rollingMode: { follow: true, offset: 0.95 },
    selectable: false,
    height: '300px',
    zoomMax: TIMELINE_ZOOM_MAX_MS,
    zoomMin: TIMELINE_ZOOM_MIN_MS
  });

  timeline.on('rangechanged', (properties) => {
    if (properties?.byUser) {
      void refreshTimeline();
    }
  });

  await refreshTimeline();
  startTimelinePolling();
};

onMounted(async () => {
  try {
    await mountTimeline();
  } catch (error) {
    timelineError.value = error instanceof Error ? error.message : 'Failed to initialize timeline';
  }

  try {
    await loadServers();
  } catch (_error) {
    // Error is reflected via serversStore.error.
  }

  try {
    await loadEvents();
  } catch (_error) {
    // Error is reflected via eventsStore.error.
  }
});

onBeforeUnmount(() => {
  stopTimelinePolling();
  if (timeline) {
    timeline.destroy();
    timeline = null;
  }
  items = null;
});
</script>

<style scoped>
.server-status {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}

.panel-body-table {
  padding: 0;
}

.panel-body-table .table {
  margin-bottom: 0;
}

.sortable-column {
  color: #337ab7;
  background: transparent;
  border: 0;
  padding: 0;
  font-weight: inherit;
  text-align: left;
  display: inline-flex;
  align-items: center;
  gap: 6px;
}

.sortable-column:hover,
.sortable-column:focus {
  color: #337ab7;
  text-decoration: underline;
  outline: none;
}

.sortable-label {
  white-space: nowrap;
}

@media (max-width: 767px) {
  .sortable-column {
    gap: 4px;
  }

  .sortable-label-min,
  .sortable-label-medium {
    display: inline-block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    vertical-align: bottom;
  }

  .sortable-label-min {
    max-width: 58px;
  }

  .sortable-label-medium {
    max-width: 32px;
  }

  .sortable-label-min {
    display: none;
  }
}

.panel-heading :deep(a) {
  color: inherit;
  text-decoration: none;
}

.panel-heading :deep(a:hover),
.panel-heading :deep(a:focus) {
  text-decoration: underline;
}
</style>
