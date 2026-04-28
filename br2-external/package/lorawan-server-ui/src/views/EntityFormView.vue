<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import EntityForm from '../components/admin/EntityForm.vue';

const props = defineProps({
  mode: {
    type: String,
    required: true
  }
});

const route = useRoute();
const entity = computed(() => String(route.params.entity || ''));
const recordId = computed(() => String(route.params.id || ''));
</script>

<template>
  <EntityForm :entity="entity" :mode="mode" :record-id="recordId" />
</template>
