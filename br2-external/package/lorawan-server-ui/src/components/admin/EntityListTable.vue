<template>
  <table class="grid table table-condensed table-hover table-striped">
    <thead>
      <tr>
        <th
          v-for="column in columns"
          :key="column"
          class="sortable-header"
          @click="$emit('sort', column)"
        >
          {{ fieldLabel(column) }}
          <span v-if="sortField === column">{{ sortDir === 'ASC' ? '▲' : '▼' }}</span>
        </th>
        <th v-if="canDelete || canEdit">{{ t('ui.actions', 'Actions') }}</th>
      </tr>
    </thead>
    <tbody>
      <tr v-if="loading">
        <td :colspan="columns.length + 1">{{ t('ui.loading', 'Loading...') }}</td>
      </tr>
      <tr v-else-if="rows.length === 0">
        <td :colspan="columns.length + 1"><strong>{{ t('ui.no_records', 'No record found') }}</strong></td>
      </tr>
      <tr v-for="row in rows" :key="row.id ?? row[idField]">
        <td v-for="column in columns" :key="column">
          <slot
            name="cell"
            :row="row"
            :column="column"
            :value="readNestedValue(row, column)"
            :formatted-value="formatValue(readNestedValue(row, column))"
            :can-edit="canEdit"
            :id-field="idField"
            :edit-to="editPathFor(row)"
          />
        </td>
        <td v-if="canDelete || canEdit" class="row-actions">
          <slot
            name="row-actions"
            :row="row"
            :can-edit="canEdit"
            :can-delete="canDelete"
            :edit-to="editPathFor(row)"
            :delete-row="() => $emit('delete-row', row)"
          />
        </td>
      </tr>
    </tbody>
  </table>
</template>

<script setup>
import { t } from '../../i18n';

defineProps({
  columns: {
    type: Array,
    required: true
  },
  rows: {
    type: Array,
    required: true
  },
  loading: {
    type: Boolean,
    default: false
  },
  sortField: {
    type: String,
    default: ''
  },
  sortDir: {
    type: String,
    default: 'ASC'
  },
  canEdit: {
    type: Boolean,
    default: false
  },
  canDelete: {
    type: Boolean,
    default: false
  },
  idField: {
    type: String,
    required: true
  },
  fieldLabel: {
    type: Function,
    required: true
  },
  editPathFor: {
    type: Function,
    required: true
  },
  readNestedValue: {
    type: Function,
    required: true
  },
  formatValue: {
    type: Function,
    required: true
  }
});

defineEmits(['sort', 'delete-row']);
</script>
