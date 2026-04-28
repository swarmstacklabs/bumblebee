<template>
  <div>
    <div v-if="allowAddField" class="form-group add-field-row">
      <label class="col-sm-2 control-label">{{ t('ui.add_field', 'Add field') }}</label>
      <div class="col-sm-4">
        <input
          :value="newFieldName"
          type="text"
          class="form-control"
          placeholder="field_name"
          @input="$emit('update:new-field-name', $event.target.value)"
        />
      </div>
      <div class="col-sm-4">
        <input
          :value="newFieldValue"
          type="text"
          class="form-control"
          placeholder="value or JSON"
          @input="$emit('update:new-field-value', $event.target.value)"
        />
      </div>
      <div class="col-sm-2">
        <button type="button" class="btn btn-default" @click="$emit('add-field')">
          {{ t('ui.add', 'Add') }}
        </button>
      </div>
    </div>

    <div class="form-group">
      <div class="col-sm-offset-2 col-sm-10">
        <button
          v-if="canSubmit"
          type="button"
          class="btn btn-primary"
          :disabled="saving"
          @click="$emit('submit')"
        >
          <span class="glyphicon glyphicon-ok" />
          <span class="hidden-xs">{{ t('ui.submit', 'Submit') }}</span>
        </button>
        <slot name="extra-actions" :submit="submit" :saving="saving" />
      </div>
    </div>
  </div>
</template>

<script setup>
import { t } from '../../i18n';

defineProps({
  allowAddField: {
    type: Boolean,
    default: false
  },
  newFieldName: {
    type: String,
    default: ''
  },
  newFieldValue: {
    type: String,
    default: ''
  },
  canSubmit: {
    type: Boolean,
    default: false
  },
  saving: {
    type: Boolean,
    default: false
  },
  submit: {
    type: Function,
    required: true
  }
});

defineEmits(['submit', 'add-field', 'update:new-field-name', 'update:new-field-value']);
</script>
