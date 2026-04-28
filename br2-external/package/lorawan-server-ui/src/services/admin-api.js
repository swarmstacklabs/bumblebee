const API_ROOT = '/api';

const QUERY_PARAM_ALIASES = {
  _page: 'page',
  _perPage: 'page_size',
  _sortField: 'sort_by',
  _sortDir: 'sort_order'
};

const normalizeQueryParams = (params = {}) =>
  Object.entries(params).reduce((normalized, [key, value]) => {
    normalized[QUERY_PARAM_ALIASES[key] || key] = value;
    return normalized;
  }, {});

const buildQuery = (params) => {
  const query = new URLSearchParams();
  Object.entries(normalizeQueryParams(params)).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') {
      query.set(key, String(value));
    }
  });
  const serialized = query.toString();
  return serialized ? `?${serialized}` : '';
};

const request = async (path, options = {}) => {
  const response = await fetch(path, {
    credentials: 'same-origin',
    headers: {
      Accept: 'application/json',
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {})
    },
    ...options
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `Request failed: ${response.status}`);
  }

  if (response.status === 204) {
    return { data: null, headers: response.headers };
  }

  const payload = await response.json();
  if (payload && typeof payload === 'object' && Array.isArray(payload.entries)) {
    const headers = new Headers(response.headers);
    if (!headers.has('x-total-count') && payload.total_entries !== undefined) {
      headers.set('x-total-count', String(payload.total_entries));
    }
    return { data: payload.entries, headers, page: payload };
  }

  return { data: payload, headers: response.headers };
};

export const listRecords = async (entity, params = {}) =>
  request(`${API_ROOT}/${encodeURIComponent(entity)}${buildQuery(params)}`);

export const readRecord = async (entity, id) =>
  request(`${API_ROOT}/${encodeURIComponent(entity)}/${encodeURIComponent(id)}`);

export const createRecord = async (entity, payload) =>
  request(`${API_ROOT}/${encodeURIComponent(entity)}`, {
    method: 'POST',
    body: JSON.stringify(payload)
  });

export const updateRecord = async (entity, id, payload) =>
  request(`${API_ROOT}/${encodeURIComponent(entity)}/${encodeURIComponent(id)}`, {
    method: 'PUT',
    body: JSON.stringify(payload)
  });

export const deleteRecord = async (entity, id) =>
  request(`${API_ROOT}/${encodeURIComponent(entity)}/${encodeURIComponent(id)}`, {
    method: 'DELETE'
  });
