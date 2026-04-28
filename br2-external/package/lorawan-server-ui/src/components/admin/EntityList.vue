<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { RouterLink } from 'vue-router';
import AdminHeaderActionLink from './AdminHeaderActionLink.vue';
import AdminPageHeader from './AdminPageHeader.vue';
import EntityListTable from './EntityListTable.vue';
import {
  getEntityLabel,
  getEntityLabelKey,
  humanizeFieldName,
  resolveEntityDefinition,
  resolveFieldLabelKey
} from '../../models/entity-definitions';
import { deleteRecord, listRecords } from '../../services/admin-api';
import { resolveEntityStore } from '../../stores/entity-store-registry';
import { t } from '../../i18n';

const props = defineProps({
  entity: {
    type: String,
    required: true
  },
  definition: {
    type: Object,
    default: null
  },
  initialPage: {
    type: Number,
    default: 1
  }
});

const emit = defineEmits(['loaded', 'load-error', 'deleted', 'delete-error']);

const rows = ref([]);
const loading = ref(false);
const error = ref('');
const currentPage = ref(props.initialPage);
const totalCount = ref(0);
const sortField = ref('');
const sortDir = ref('ASC');

const mergedDefinition = computed(() => ({
  ...resolveEntityDefinition(props.entity),
  ...(props.definition || {})
}));
const idField = computed(() => mergedDefinition.value.idField);
const columns = computed(() => {
  const explicit = mergedDefinition.value.listFields || [];
  if (explicit.length > 0) {
    return explicit;
  }
  const first = rows.value[0] || {};
  return Object.keys(first).slice(0, 6);
});

const totalPages = computed(() =>
  Math.max(1, Math.ceil(totalCount.value / Math.max(1, mergedDefinition.value.perPage)))
);
const entityLabel = computed(() =>
  t(getEntityLabelKey(props.entity), getEntityLabel(props.entity))
);
const title = computed(() => `${entityLabel.value} ${t('ui.list', 'List')}`);
const canCreate = computed(() => mergedDefinition.value.canCreate);
const canEdit = computed(() => mergedDefinition.value.canEdit);
const canDelete = computed(() => mergedDefinition.value.canDelete);
const createTo = computed(() => `/${props.entity}/create`);

const readNestedValue = (record, path) => {
  if (!record || !path) {
    return null;
  }
  return path.split('.').reduce((acc, key) => (acc == null ? null : acc[key]), record);
};

const formatValue = (value) => {
  if (value === null || value === undefined) {
    return '';
  }
  if (typeof value === 'boolean') {
    return value ? 'yes' : 'no';
  }
  if (typeof value === 'object') {
    const text = JSON.stringify(value);
    return text.length > 80 ? `${text.slice(0, 77)}...` : text;
  }
  return String(value);
};

const normalizeScopeValues = (value) => {
  if (Array.isArray(value)) {
    return value.map((item) => String(item || '').trim()).filter(Boolean);
  }
  if (typeof value === 'string') {
    return value
      .split(',')
      .map((item) => item.trim())
      .filter(Boolean);
  }
  return [];
};

const fieldLabel = (field) => {
  const key = resolveFieldLabelKey(props.entity, field, 'list');
  return key ? t(key, humanizeFieldName(field)) : humanizeFieldName(field);
};

const editPathFor = (row) => {
  const id = row?.id ?? row?.[idField.value];
  return `/${props.entity}/edit/${encodeURIComponent(String(id || ''))}`;
};

const loadList = async () => {
  loading.value = true;
  error.value = '';
  try {
    const entityStore = resolveEntityStore(props.entity);
    if (entityStore) {
      await entityStore.fetchAll();
      const { rows: pagedRows, totalCount: totalFromStore } = entityStore.listPage({
        page: currentPage.value,
        perPage: mergedDefinition.value.perPage,
        sortField: sortField.value,
        sortDir: sortDir.value,
        valueReader: readNestedValue
      });
      rows.value = pagedRows;
      totalCount.value = totalFromStore;
      emit('loaded', rows.value);
      return;
    }

    const params = {
      page: currentPage.value,
      page_size: mergedDefinition.value.perPage
    };
    if (sortField.value) {
      params.sort_by = sortField.value;
      params.sort_order = sortDir.value;
    }
    const { data, headers } = await listRecords(props.entity, params);
    rows.value = Array.isArray(data) ? data : [];
    totalCount.value = Number(headers.get('x-total-count') || rows.value.length);
    emit('loaded', rows.value);
  } catch (err) {
    rows.value = [];
    totalCount.value = 0;
    error.value = err instanceof Error ? err.message : String(err);
    emit('load-error', error.value);
  } finally {
    loading.value = false;
  }
};

const resetAndReload = () => {
  currentPage.value = 1;
  sortField.value = '';
  sortDir.value = 'ASC';
  loadList();
};

const changeSort = (column) => {
  if (sortField.value === column) {
    sortDir.value = sortDir.value === 'ASC' ? 'DESC' : 'ASC';
  } else {
    sortField.value = column;
    sortDir.value = 'ASC';
  }
  currentPage.value = 1;
  loadList();
};

const goToPage = (page) => {
  currentPage.value = Math.min(Math.max(1, page), totalPages.value);
  loadList();
};

const deleteRow = async (row) => {
  const id = row?.id ?? row?.[idField.value];
  if (!id) {
    return;
  }
  const ok = window.confirm(`Delete ${props.entity} "${id}"?`);
  if (!ok) {
    return;
  }
  try {
    const entityStore = resolveEntityStore(props.entity);
    if (entityStore) {
      await entityStore.deleteOne(String(id));
    } else {
      await deleteRecord(props.entity, String(id));
    }
    emit('deleted', row);
    await loadList();
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
    emit('delete-error', error.value);
  }
};

watch(
  () => props.entity,
  () => {
    resetAndReload();
  }
);

onMounted(loadList);
</script>

<template>
  <div>
    <AdminPageHeader :title="title">
      <template #actions>
        <slot
          name="header-actions"
          :entity="props.entity"
          :definition="mergedDefinition"
          :create-to="createTo"
          :can-create="canCreate"
          :refresh="loadList"
        >
          <AdminHeaderActionLink
            v-if="canCreate"
            :to="createTo"
            icon-class="glyphicon-plus"
            label-key="ui.create"
            fallback-label="Create"
          />
        </slot>
      </template>
    </AdminPageHeader>

    <slot
      name="before-table"
      :rows="rows"
      :loading="loading"
      :refresh="loadList"
      :error="error"
    />

    <div class="row list-view">
      <div class="col-lg-12">
        <div v-if="error" class="alert alert-danger">{{ error }}</div>

        <EntityListTable
          :columns="columns"
          :rows="rows"
          :loading="loading"
          :sort-field="sortField"
          :sort-dir="sortDir"
          :can-edit="canEdit"
          :can-delete="canDelete"
          :id-field="idField"
          :field-label="fieldLabel"
          :edit-path-for="editPathFor"
          :read-nested-value="readNestedValue"
          :format-value="formatValue"
          @sort="changeSort"
          @delete-row="deleteRow"
        >
          <template #cell="slotProps">
            <slot
              name="cell"
              :row="slotProps.row"
              :column="slotProps.column"
              :value="slotProps.value"
              :formatted-value="slotProps.formattedValue"
              :can-edit="slotProps.canEdit"
              :id-field="slotProps.idField"
              :edit-to="slotProps.editTo"
            >
              <template v-if="props.entity === 'users' && slotProps.column === 'scopes'">
                <span
                  v-for="scope in normalizeScopeValues(slotProps.value)"
                  :key="scope"
                  class="label label-default user-scope-tag"
                >
                  {{ scope }}
                </span>
                <span v-if="normalizeScopeValues(slotProps.value).length === 0">
                  {{ slotProps.formattedValue }}
                </span>
              </template>
              <template v-else-if="props.entity === 'users' && slotProps.column === 'send_alerts'">
                <span
                  :class="[
                    'glyphicon',
                    slotProps.value ? 'glyphicon-ok text-success' : 'glyphicon-remove text-danger'
                  ]"
                  aria-hidden="true"
                />
              </template>
              <RouterLink
                v-else-if="slotProps.canEdit && slotProps.column === slotProps.idField"
                :to="slotProps.editTo"
              >
                {{ slotProps.formattedValue }}
              </RouterLink>
              <span v-else>{{ slotProps.formattedValue }}</span>
            </slot>
          </template>

          <template #row-actions="slotProps">
            <slot
              name="row-actions"
              :row="slotProps.row"
              :can-edit="slotProps.canEdit"
              :can-delete="slotProps.canDelete"
              :edit-to="slotProps.editTo"
              :delete-row="slotProps.deleteRow"
            >
              <RouterLink
                v-if="slotProps.canEdit"
                class="btn btn-xs btn-default"
                :to="slotProps.editTo"
              >
                {{ t('ui.edit', 'Edit') }}
              </RouterLink>
              <button
                v-if="slotProps.canDelete"
                type="button"
                class="btn btn-xs btn-danger"
                @click="slotProps.deleteRow()"
              >
                {{ t('ui.delete', 'Delete') }}
              </button>
            </slot>
          </template>
        </EntityListTable>
      </div>
    </div>

    <slot
      name="after-table"
      :rows="rows"
      :loading="loading"
      :refresh="loadList"
      :error="error"
    />

    <div class="row">
      <div class="col-lg-12">
        <nav class="pagination-bar">
          <div class="total">
            <strong>{{ t('ui.total', 'Total') }}: {{ totalCount }}</strong>
          </div>
          <ul class="pagination pagination-sm">
            <li :class="{ disabled: currentPage <= 1 }">
              <a href="#" @click.prevent="goToPage(currentPage - 1)">{{ t('ui.prev', 'Prev') }}</a>
            </li>
            <li class="active"><a>{{ currentPage }}</a></li>
            <li :class="{ disabled: currentPage >= totalPages }">
              <a href="#" @click.prevent="goToPage(currentPage + 1)">{{ t('ui.next', 'Next') }}</a>
            </li>
          </ul>
        </nav>
      </div>
    </div>
  </div>
</template>
