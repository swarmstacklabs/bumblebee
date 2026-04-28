<template>
  <ul v-if="sections.length > 0" class="nav nav-tabs entity-form-tabs">
    <li
      v-for="section in sections"
      :key="section.id"
      :class="{ active: section.id === activeSectionId }"
    >
      <a href="#" @click.prevent="$emit('activate', section.id)">
        {{ sectionLabel(section) }}
      </a>
    </li>
  </ul>
</template>

<script setup>
defineProps({
  sections: {
    type: Array,
    required: true
  },
  activeSectionId: {
    type: String,
    default: ''
  },
  sectionLabel: {
    type: Function,
    required: true
  }
});

defineEmits(['activate']);
</script>
