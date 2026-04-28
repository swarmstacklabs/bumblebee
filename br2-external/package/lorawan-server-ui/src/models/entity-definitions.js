const DEFAULT_PER_PAGE = 30;

const COMMON_FIELD_LABEL_KEYS = {
  id: 'field.id',
  name: 'field.name',
  sname: 'field.server_name',
  app: 'field.application',
  desc: 'field.description',
  datetime: 'field.datetime',
  email: 'field.email',
  region: 'field.region',
  admins: 'field.administrators',
  area: 'field.area',
  network: 'field.network',
  group: 'field.group',
  profile: 'field.profile',
  disabled: 'field.disabled',
  enabled: 'field.enabled',
  health_alerts: 'field.alerts',
  send_alerts: 'field.send_alerts',
  log_ignored: 'field.log_ignored',
  mac: 'field.mac',
  deveui: 'field.deveui',
  devaddr: 'field.devaddr',
  connid: 'field.connector_id',
  frid: 'field.frame_id',
  evid: 'field.event_id',
  items_per_page: 'field.items_per_page',
  admin_url: 'field.admin_url',
  email_from: 'field.email_from',
  modules: 'field.modules',
  memory: 'field.memory',
  disk: 'field.disk',
  netid: 'field.netid',
  can_join: 'field.can_join',
  max_fcnt_gap: 'field.max_fcnt_gap',
  adr_use: 'field.adr_use',
  txwin: 'field.tx_window',
  last_rx: 'field.last_rx',
  appeui: 'field.appeui',
  mask: 'field.mask',
  format: 'field.format',
  parse_uplink: 'field.parse_uplink',
  build: 'field.build',
  event_fields: 'field.event_fields',
  uri: 'field.uri',
  publish_qos: 'field.publish_qos',
  subscribe_qos: 'field.subscribe_qos',
  severity: 'field.severity',
  entity: 'field.entity',
  eid: 'field.entity_id',
  text: 'field.message',
  fcnt: 'field.fcnt',
  port: 'field.port',
  data: 'field.data',
  gpspos: 'field.gps_position'
};

const ENTITY_FIELD_LABEL_KEYS = {
  servers: {
    'modules.bumblebee': 'field.server_version'
  }
};

const PAGE_FIELD_LABEL_KEYS = {
  list: {
    events: {
      entity: 'field.entity_type'
    }
  },
  form: {}
};

const definitions = {
  config: {
    label: 'Configuration',
    idField: 'name',
    canList: false,
    canCreate: false,
    canEdit: true,
    canDelete: false,
    listFields: ['name', 'admin_url', 'items_per_page', 'email_from'],
    formSections: {
      edit: [
        {
          id: 'general',
          labelKey: 'section.general',
          label: 'General',
          fields: ['admin_url', 'items_per_page', 'slack_token', 'app']
        },
        {
          id: 'email',
          labelKey: 'section.email',
          label: 'E-Mail',
          fields: ['email_from', 'email_server', 'email_user', 'email_password']
        }
      ]
    },
    perPage: DEFAULT_PER_PAGE
  },
  servers: {
    label: 'Servers',
    idField: 'sname',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['sname', 'modules.bumblebee', 'memory', 'disk', 'health_alerts'],
    formSections: {
      edit: [
        {
          id: 'general',
          labelKey: 'section.general',
          label: 'General',
          fields: ['sname', 'modules.bumblebee']
        },
        {
          id: 'status',
          labelKey: 'section.status',
          label: 'Status',
          fields: ['health_alerts', 'memory', 'disk']
        }
      ]
    },
    perPage: DEFAULT_PER_PAGE
  },
  users: {
    label: 'Users',
    idField: 'name',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['name', 'scopes', 'email', 'send_alerts'],
    createDefaults: {
      name: '',
      password: '',
      scopes: [],
      email: '',
      send_alerts: false
    },
    perPage: DEFAULT_PER_PAGE
  },
  areas: {
    label: 'Areas',
    idField: 'name',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['name', 'region', 'admins', 'log_ignored'],
    perPage: DEFAULT_PER_PAGE
  },
  gateways: {
    label: 'Gateways',
    idField: 'mac',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['mac', 'area', 'network', 'gpspos', 'health_alerts'],
    perPage: DEFAULT_PER_PAGE
  },
  networks: {
    label: 'Networks',
    idField: 'name',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['name', 'region', 'netid', 'disabled', 'health_alerts'],
    perPage: DEFAULT_PER_PAGE
  },
  multicast_channels: {
    label: 'Multicast Channels',
    idField: 'devaddr',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['devaddr', 'group', 'nwkskey', 'appskey', 'fport'],
    perPage: DEFAULT_PER_PAGE
  },
  groups: {
    label: 'Groups',
    idField: 'name',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['name', 'network', 'can_join', 'max_fcnt_gap', 'health_alerts'],
    perPage: DEFAULT_PER_PAGE
  },
  profiles: {
    label: 'Profiles',
    idField: 'name',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['name', 'group', 'app', 'adr_use', 'txwin'],
    perPage: DEFAULT_PER_PAGE
  },
  devices: {
    label: 'Devices',
    idField: 'deveui',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['deveui', 'appeui', 'profile', 'health_alerts'],
    perPage: DEFAULT_PER_PAGE
  },
  nodes: {
    label: 'Nodes',
    idField: 'devaddr',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['devaddr', 'deveui', 'profile', 'last_rx', 'health_alerts'],
    perPage: DEFAULT_PER_PAGE
  },
  ignored_nodes: {
    label: 'Ignored Nodes',
    idField: 'devaddr',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['devaddr', 'mask'],
    perPage: DEFAULT_PER_PAGE
  },
  handlers: {
    label: 'Handlers',
    idField: 'app',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['app', 'format', 'parse_uplink', 'build', 'event_fields'],
    perPage: DEFAULT_PER_PAGE
  },
  connectors: {
    label: 'Connectors',
    idField: 'connid',
    canList: true,
    canCreate: true,
    canEdit: true,
    canDelete: true,
    listFields: ['connid', 'uri', 'publish_qos', 'subscribe_qos', 'enabled'],
    perPage: DEFAULT_PER_PAGE
  },
  events: {
    label: 'Events',
    idField: 'evid',
    canList: true,
    canCreate: false,
    canEdit: false,
    canDelete: false,
    listFields: ['datetime', 'severity', 'entity', 'eid', 'text'],
    perPage: DEFAULT_PER_PAGE
  },
  rxframes: {
    label: 'Frames',
    idField: 'frid',
    canList: true,
    canCreate: false,
    canEdit: false,
    canDelete: false,
    listFields: ['datetime', 'mac', 'devaddr', 'adr', 'fcnt', 'port', 'data'],
    perPage: DEFAULT_PER_PAGE
  }
};

const FALLBACK = {
  label: 'Entity',
  idField: 'id',
  canList: true,
  canCreate: true,
  canEdit: true,
  canDelete: true,
  listFields: ['id'],
  perPage: DEFAULT_PER_PAGE
};

export const resolveEntityDefinition = (entityName) => {
  const key = String(entityName || '').trim();
  const definition = definitions[key] || {};
  return {
    ...FALLBACK,
    ...definition,
    entity: key
  };
};

export const getEntityLabel = (entityName) => resolveEntityDefinition(entityName).label;

export const getEntityLabelKey = (entityName) => `entity.${String(entityName || '').trim()}`;

export const resolveFieldLabelKey = (entityName, fieldName, page = 'form') => {
  const entity = String(entityName || '').trim();
  const field = String(fieldName || '').trim();
  const pageMap = PAGE_FIELD_LABEL_KEYS[page] || {};

  const pageSpecific = pageMap[entity]?.[field];
  if (pageSpecific) {
    return pageSpecific;
  }

  const entitySpecific = ENTITY_FIELD_LABEL_KEYS[entity]?.[field];
  if (entitySpecific) {
    return entitySpecific;
  }

  if (COMMON_FIELD_LABEL_KEYS[field]) {
    return COMMON_FIELD_LABEL_KEYS[field];
  }

  if (field.includes('.')) {
    const tail = field.split('.').pop();
    if (tail && COMMON_FIELD_LABEL_KEYS[tail]) {
      return COMMON_FIELD_LABEL_KEYS[tail];
    }
  }

  return null;
};

export const humanizeFieldName = (fieldName) =>
  String(fieldName || '')
    .split('.')
    .pop()
    .replaceAll('_', ' ')
    .replaceAll('-', ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/\b\w/g, (letter) => letter.toUpperCase());

export const resolveFormSections = (entityName, mode = 'edit') => {
  const definition = resolveEntityDefinition(entityName);
  const sections = definition.formSections || {};
  return sections[mode] || sections.default || [];
};
