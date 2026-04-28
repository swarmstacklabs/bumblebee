<template>
  <div class="row list-header">
    <div class="col-lg-12">
      <div class="page-header">
        <div class="pull-right">
          <slot name="actions" />
        </div>
        <h1>{{ title }}</h1>
      </div>
    </div>
  </div>
</template>

<script setup>
defineProps({
  title: {
    type: String,
    required: true
  }
});
</script>
