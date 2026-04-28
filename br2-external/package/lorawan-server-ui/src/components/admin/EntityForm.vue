<template>
  <div>
    <AdminPageHeader :title="title">
      <template #actions>
        <slot
          name="header-actions"
          :entity="props.entity"
          :definition="mergedDefinition"
          :list-to="listTo"
        >
          <AdminHeaderActionLink
            :to="listTo"
            icon-class="glyphicon-list"
            label-key="ui.list"
            fallback-label="List"
          />
        </slot>
      </template>
    </AdminPageHeader>

    <div class="tab-pane">
      <div class="row">
        <div class="col-lg-12">
          <div v-if="error" class="alert alert-danger">{{ error }}</div>
          <div v-if="success" class="alert alert-success">{{ success }}</div>
          <div v-if="loading" class="alert alert-info">{{ t('ui.loading', 'Loading...') }}</div>

          <form v-if="!loading" class="form-horizontal" @submit.prevent="submit">
            <slot
              name="before-fields"
              :entity="props.entity"
              :mode="props.mode"
              :record-id="props.recordId"
              :definition="mergedDefinition"
              :sections="sections"
              :active-section-id="activeSectionId"
              :set-active-section="activateSection"
            />

            <EntityFormTabs
              :sections="sections"
              :active-section-id="activeSectionId"
              :section-label="sectionLabel"
              @activate="activateSection"
            />

            <EntityFormFieldRow
              v-for="field in visibleFields"
              :key="field"
              :field="field"
              :label="fieldLabelWithRequiredMark(field)"
              :kind="fieldKinds[field]"
              :options="fieldOptions[field] || []"
              :disabled="isFieldDisabled(field)"
              :primitive-values="primitiveValues"
              :json-values="jsonValues"
            >
              <template v-if="$slots.field" #field="slotProps">
                <slot
                  name="field"
                  :field="slotProps.field"
                  :kind="slotProps.kind"
                  :disabled="slotProps.disabled"
                  :primitive-values="slotProps.primitiveValues"
                  :json-values="slotProps.jsonValues"
                />
              </template>
            </EntityFormFieldRow>

            <slot
              name="after-fields"
              :entity="props.entity"
              :mode="props.mode"
              :record-id="props.recordId"
              :definition="mergedDefinition"
              :ordered-fields="orderedFields"
              :visible-fields="visibleFields"
              :sections="sections"
              :active-section-id="activeSectionId"
              :set-active-section="activateSection"
            />

            <EntityFormActions
              :allow-add-field="allowAddFieldForEntity"
              :new-field-name="newFieldName"
              :new-field-value="newFieldValue"
              :can-submit="canSubmit"
              :saving="saving"
              :submit="submit"
              @update:new-field-name="setNewFieldName"
              @update:new-field-value="setNewFieldValue"
              @add-field="addField"
              @submit="submit"
            >
              <template #extra-actions="slotProps">
                <slot
                  name="extra-actions"
                  :submit="slotProps.submit"
                  :saving="slotProps.saving"
                  :payload-builder="buildPayload"
                />
              </template>
            </EntityFormActions>
          </form>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import AdminHeaderActionLink from './AdminHeaderActionLink.vue';
import AdminPageHeader from './AdminPageHeader.vue';
import EntityFormActions from './EntityFormActions.vue';
import EntityFormFieldRow from './EntityFormFieldRow.vue';
import EntityFormTabs from './EntityFormTabs.vue';
import {
  getEntityLabel,
  getEntityLabelKey,
  humanizeFieldName,
  resolveEntityDefinition,
  resolveFieldLabelKey,
  resolveFormSections
} from '../../models/entity-definitions';
import { createRecord, readRecord, updateRecord } from '../../services/admin-api';
import { useScopesStore } from '../../stores/scopes';
import { resolveEntityStore } from '../../stores/entity-store-registry';
import { t } from '../../i18n';

const props = defineProps({
  entity: {
    type: String,
    required: true
  },
  mode: {
    type: String,
    required: true
  },
  recordId: {
    type: String,
    default: ''
  },
  definition: {
    type: Object,
    default: null
  },
  allowAddField: {
    type: Boolean,
    default: true
  },
  redirectAfterCreate: {
    type: Boolean,
    default: true
  }
});

const emit = defineEmits(['loaded', 'load-error', 'submit-success', 'submit-error']);
const router = useRouter();
const scopesStore = useScopesStore();

const loading = ref(false);
const saving = ref(false);
const error = ref('');
const success = ref('');

const fieldKinds = ref({});
const primitiveValues = ref({});
const jsonValues = ref({});

const newFieldName = ref('');
const newFieldValue = ref('');
const activeSectionId = ref('');

const mergedDefinition = computed(() => ({
  ...resolveEntityDefinition(props.entity),
  ...(props.definition || {})
}));
const usersScopeOptions = computed(() => (props.entity === 'users' ? scopesStore.scopes : []));
const fieldOptions = computed(() => {
  if (props.entity !== 'users') {
    return {};
  }
  return {
    scopes: usersScopeOptions.value
  };
});

const canSubmit = computed(() => {
  if (props.mode === 'create') {
    return mergedDefinition.value.canCreate;
  }
  return mergedDefinition.value.canEdit;
});
const allowAddFieldForEntity = computed(() => props.allowAddField && props.entity !== 'users');

const entityLabel = computed(() =>
  t(getEntityLabelKey(props.entity), getEntityLabel(props.entity))
);
const title = computed(() => {
  if (props.mode === 'create') {
    return `${t('ui.create', 'Create')} ${entityLabel.value}`;
  }
  return `${t('ui.edit', 'Edit')} ${entityLabel.value}: ${props.recordId}`;
});
const listTo = computed(() => `/${props.entity}/list`);

const orderedFields = computed(() => {
  const all = Object.keys(fieldKinds.value);
  const id = mergedDefinition.value.idField;
  if (all.includes(id)) {
    return [id, ...all.filter((field) => field !== id)];
  }
  return all;
});

const sections = computed(() => {
  const base = resolveFormSections(props.entity, props.mode).filter((section) => section?.id);
  if (base.length === 0) {
    return [];
  }

  const assigned = new Set(base.flatMap((section) => section.fields || []));
  const unassigned = orderedFields.value.filter((field) => !assigned.has(field));
  if (unassigned.length === 0) {
    return base;
  }

  return [
    ...base,
    {
      id: 'other',
      labelKey: 'section.other',
      label: 'Other',
      fields: unassigned,
      auto: true
    }
  ];
});

const hasSections = computed(() => sections.value.length > 0);
const activeSection = computed(
  () => sections.value.find((section) => section.id === activeSectionId.value) || sections.value[0] || null
);
const hiddenFields = computed(() => new Set(['id']));
const visibleFields = computed(() => {
  if (!hasSections.value || !activeSection.value) {
    return orderedFields.value.filter((field) => !hiddenFields.value.has(field));
  }
  const allowed = new Set(activeSection.value.fields || []);
  return orderedFields.value.filter((field) => allowed.has(field) && !hiddenFields.value.has(field));
});

const resetFormState = () => {
  fieldKinds.value = {};
  primitiveValues.value = {};
  jsonValues.value = {};
};

const classifyField = (field, value) => {
  if (props.entity === 'users' && field === 'scopes') {
    fieldKinds.value[field] = 'string-array';
    primitiveValues.value[field] = Array.isArray(value)
      ? value.map((item) => String(item)).filter(Boolean)
      : [];
    return;
  }
  if (Array.isArray(value) || (value && typeof value === 'object')) {
    fieldKinds.value[field] = 'json';
    jsonValues.value[field] = JSON.stringify(value, null, 2);
    return;
  }
  if (typeof value === 'boolean') {
    fieldKinds.value[field] = 'boolean';
    primitiveValues.value[field] = value;
    return;
  }
  if (typeof value === 'number') {
    fieldKinds.value[field] = 'number';
    primitiveValues.value[field] = value;
    return;
  }
  fieldKinds.value[field] = 'string';
  primitiveValues.value[field] = value == null ? '' : String(value);
};

const fieldLabel = (field) => {
  const key = resolveFieldLabelKey(props.entity, field, 'form');
  return key ? t(key, humanizeFieldName(field)) : humanizeFieldName(field);
};

const sendAlertsEnabled = computed(() => primitiveValues.value.send_alerts === true);

const isUsersRequiredField = (field) => {
  if (props.entity !== 'users') {
    return false;
  }
  if (field === 'name' || field === 'scopes') {
    return true;
  }
  if (field === 'password' && props.mode === 'create') {
    return true;
  }
  if (field === 'email' && sendAlertsEnabled.value) {
    return true;
  }
  return false;
};

const fieldLabelWithRequiredMark = (field) => {
  const base = fieldLabel(field);
  return isUsersRequiredField(field) ? `${base} *` : base;
};

const sectionLabel = (section) => {
  const fallback =
    section.label ||
    String(section.id || '')
      .replaceAll('_', ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .replace(/\b\w/g, (letter) => letter.toUpperCase());
  return section.labelKey ? t(section.labelKey, fallback) : fallback;
};

const activateSection = (sectionId) => {
  activeSectionId.value = sectionId;
};

const hydrateFromObject = (payload) => {
  resetFormState();
  const source =
    props.entity === 'users'
      ? { ...createDefaultsPayload(), ...(payload || {}) }
      : payload || {};
  Object.entries(source).forEach(([field, value]) => classifyField(field, value));
};

const createDefaultsPayload = () => {
  const defaults = mergedDefinition.value.createDefaults;
  if (defaults && typeof defaults === 'object') {
    return defaults;
  }
  return { [mergedDefinition.value.idField]: '' };
};

const ensureEntitySupportData = async () => {
  if (props.entity === 'users') {
    await scopesStore.fetchScopes();
  }
};

const loadRecord = async () => {
  loading.value = true;
  error.value = '';
  success.value = '';

  try {
    await ensureEntitySupportData();
    if (props.mode === 'create') {
      hydrateFromObject(createDefaultsPayload());
      emit('loaded', null);
      return;
    }
    const entityStore = resolveEntityStore(props.entity);
    if (entityStore) {
      const data = await entityStore.fetchById(props.recordId);
      hydrateFromObject(data || {});
      emit('loaded', data);
      return;
    }

    const { data } = await readRecord(props.entity, props.recordId);
    hydrateFromObject(data || {});
    emit('loaded', data);
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
    emit('load-error', error.value);
  } finally {
    loading.value = false;
  }
};

const isFieldDisabled = (field) => props.mode === 'edit' && field === mergedDefinition.value.idField;

const parseLooseValue = (raw) => {
  const value = String(raw || '').trim();
  if (value === '') {
    return '';
  }
  if (value === 'true') {
    return true;
  }
  if (value === 'false') {
    return false;
  }
  if (/^-?\d+(\.\d+)?$/.test(value)) {
    return Number(value);
  }
  if ((value.startsWith('{') && value.endsWith('}')) || (value.startsWith('[') && value.endsWith(']'))) {
    return JSON.parse(value);
  }
  return value;
};

const addField = () => {
  error.value = '';
  const field = newFieldName.value.trim();
  if (!field) {
    return;
  }
  if (Object.prototype.hasOwnProperty.call(fieldKinds.value, field)) {
    error.value = `Field "${field}" already exists.`;
    return;
  }

  try {
    classifyField(field, parseLooseValue(newFieldValue.value));
    newFieldName.value = '';
    newFieldValue.value = '';
  } catch {
    error.value = 'Invalid JSON in new field value.';
  }
};

const setNewFieldName = (value) => {
  newFieldName.value = String(value || '').trim();
};

const setNewFieldValue = (value) => {
  newFieldValue.value = String(value || '');
};

const validateUsersRequiredFields = (payload) => {
  if (props.entity !== 'users') {
    return '';
  }

  const name = String(payload.name || '').trim();
  if (!name) {
    return 'Name is required.';
  }

  if (props.mode === 'create') {
    const password = String(payload.password || '').trim();
    if (!password) {
      return 'Password is required.';
    }
  }

  if (!Array.isArray(payload.scopes) || payload.scopes.length === 0) {
    return 'At least one scope is required.';
  }

  if (typeof payload.send_alerts !== 'boolean') {
    return 'Send alerts is required.';
  }

  if (payload.send_alerts === true) {
    const email = String(payload.email || '').trim();
    if (!email) {
      return 'Email is required when send alerts is enabled.';
    }
  }

  return '';
};

const buildPayload = () => {
  const payload = {};
  for (const field of Object.keys(fieldKinds.value)) {
    if (hiddenFields.value.has(field)) {
      continue;
    }
    const kind = fieldKinds.value[field];
    if (kind === 'string-array') {
      payload[field] = Array.isArray(primitiveValues.value[field])
        ? primitiveValues.value[field].map((item) => String(item)).filter(Boolean)
        : [];
      continue;
    }
    if (kind === 'json') {
      const raw = String(jsonValues.value[field] || '').trim();
      if (raw === '') {
        payload[field] = null;
      } else {
        payload[field] = JSON.parse(raw);
      }
      continue;
    }
    payload[field] = primitiveValues.value[field];
  }
  return payload;
};

const submit = async () => {
  saving.value = true;
  error.value = '';
  success.value = '';

  try {
    const payload = buildPayload();
    const validationError = validateUsersRequiredFields(payload);
    if (validationError) {
      throw new Error(validationError);
    }
    const entityStore = resolveEntityStore(props.entity);
    if (props.mode === 'create') {
      const result =
        entityStore
          ? await entityStore.createOne(payload)
          : await createRecord(props.entity, payload);
      success.value = 'Record created.';
      emit('submit-success', { mode: props.mode, payload, result });
      const id = payload[mergedDefinition.value.idField];
      if (props.redirectAfterCreate && id) {
        await router.push(`/${props.entity}/edit/${encodeURIComponent(String(id))}`);
      }
    } else {
      const result =
        entityStore
          ? await entityStore.updateOne(props.recordId, payload)
          : await updateRecord(props.entity, props.recordId, payload);
      success.value = 'Record updated.';
      emit('submit-success', { mode: props.mode, payload, result });
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
    emit('submit-error', error.value);
  } finally {
    saving.value = false;
  }
};

watch(
  () => [props.entity, props.recordId, props.mode],
  () => {
    loadRecord();
  }
);

watch(
  sections,
  (nextSections) => {
    if (nextSections.length === 0) {
      activeSectionId.value = '';
      return;
    }
    if (!nextSections.some((section) => section.id === activeSectionId.value)) {
      activeSectionId.value = nextSections[0].id;
    }
  },
  { immediate: true }
);

onMounted(loadRecord);
</script>
