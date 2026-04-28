<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import EntityList from '../components/admin/EntityList.vue';

const route = useRoute();
const entity = computed(() => String(route.params.entity || ''));
</script>

<template>
  <EntityList :entity="entity" />
</template>
