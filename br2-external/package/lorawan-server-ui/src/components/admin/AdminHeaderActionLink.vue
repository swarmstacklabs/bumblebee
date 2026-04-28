<template>
  <RouterLink class="btn btn-default" :to="to">
    <span :class="`glyphicon ${iconClass}`" aria-hidden="true" />
    <span class="hidden-xs">{{ t(labelKey, fallbackLabel) }}</span>
  </RouterLink>
</template>

<script setup>
import { RouterLink } from 'vue-router';
import { t } from '../../i18n';

defineProps({
  to: {
    type: [String, Object],
    required: true
  },
  iconClass: {
    type: String,
    required: true
  },
  labelKey: {
    type: String,
    required: true
  },
  fallbackLabel: {
    type: String,
    required: true
  }
});
</script>
