<template>
  <div class="form-group">
    <label class="col-sm-2 control-label">{{ label }}</label>
    <div class="col-sm-10">
      <slot
        name="field"
        :field="field"
        :kind="kind"
        :disabled="disabled"
        :primitive-values="primitiveValues"
        :json-values="jsonValues"
      >
        <template v-if="kind === 'boolean'">
          <div class="boolean-field-control">
            <input
              v-model="primitiveValues[field]"
              type="checkbox"
              :disabled="disabled"
            />
          </div>
        </template>

        <template v-else-if="kind === 'number'">
          <input
            v-model.number="primitiveValues[field]"
            type="number"
            class="form-control"
            :disabled="disabled"
          />
        </template>

        <template v-else-if="kind === 'json'">
          <textarea
            v-model="jsonValues[field]"
            rows="4"
            class="form-control"
            :disabled="disabled"
          />
          <small class="text-muted">{{ t('ui.json_hint', 'JSON object or array') }}</small>
        </template>

        <template v-else-if="kind === 'string-array'">
          <div class="scope-picker">
            <div class="input-group">
              <select v-model="pendingOption" class="form-control" :disabled="disabled || availableOptions.length === 0">
                <option value="">{{ t('ui.select_scope', 'Select scope') }}</option>
                <option v-for="option in availableOptions" :key="option" :value="option">{{ option }}</option>
              </select>
              <span class="input-group-btn">
                <button
                  type="button"
                  class="btn btn-default"
                  :disabled="disabled || !pendingOption"
                  @click="addPendingOption"
                >
                  {{ t('ui.add', 'Add') }}
                </button>
              </span>
            </div>

            <div v-if="selectedValues.length > 0" class="selected-scope-list">
              <button
                v-for="scope in selectedValues"
                :key="scope"
                type="button"
                class="ui-select-match-item btn btn-default btn-xs selected-scope-chip"
                :disabled="disabled"
              >
                <span
                  v-if="!disabled"
                  class="close ui-select-match-close"
                  @click.stop="removeScope(scope)"
                >
                  &nbsp;×
                </span>
                <span>{{ scope }}</span>
              </button>
            </div>
          </div>
        </template>

        <template v-else>
          <input
            v-model="primitiveValues[field]"
            :type="isPasswordField ? 'password' : 'text'"
            class="form-control"
            :disabled="disabled"
          />
        </template>
      </slot>
    </div>
  </div>
</template>

<script setup>
import { computed, ref } from 'vue';
import { t } from '../../i18n';

const props = defineProps({
  field: {
    type: String,
    required: true
  },
  label: {
    type: String,
    required: true
  },
  kind: {
    type: String,
    required: true
  },
  options: {
    type: Array,
    default: () => []
  },
  disabled: {
    type: Boolean,
    default: false
  },
  primitiveValues: {
    type: Object,
    required: true
  },
  jsonValues: {
    type: Object,
    required: true
  }
});

const pendingOption = ref('');

const selectedValues = computed(() => {
  const raw = props.primitiveValues[props.field];
  return Array.isArray(raw) ? raw.map((item) => String(item)).filter(Boolean) : [];
});

const availableOptions = computed(() =>
  props.options.filter((option) => !selectedValues.value.includes(option))
);

const isPasswordField = computed(() => props.kind === 'string' && props.field === 'password');

const setSelectedValues = (values) => {
  props.primitiveValues[props.field] = values;
};

const addPendingOption = () => {
  const next = String(pendingOption.value || '').trim();
  if (!next) {
    return;
  }
  if (selectedValues.value.includes(next)) {
    pendingOption.value = '';
    return;
  }
  setSelectedValues([...selectedValues.value, next]);
  pendingOption.value = '';
};

const removeScope = (scope) => {
  setSelectedValues(selectedValues.value.filter((item) => item !== scope));
};
</script>
