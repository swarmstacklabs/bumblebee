# Reusable Admin Components

These components provide reusable CRUD behavior and extension points for custom pages.

## EntityList

File: `src/components/admin/EntityList.vue`

Props:
- `entity: string` (required)
- `definition?: object` (optional entity override)
- `initialPage?: number`

Events:
- `loaded(rows)`
- `load-error(message)`
- `deleted(row)`
- `delete-error(message)`

Slots:
- `header-actions`
- `before-table`
- `cell`
- `row-actions`
- `after-table`

Example:

```vue
<script setup>
import EntityList from '@/components/admin/EntityList.vue';
</script>

<template>
  <EntityList entity="devices">
    <template #header-actions="{ createTo, refresh }">
      <RouterLink class="btn btn-default" :to="createTo">Create</RouterLink>
      <button class="btn btn-default" @click="refresh">Reload</button>
    </template>

    <template #row-actions="{ row, editTo, deleteRow }">
      <RouterLink class="btn btn-xs btn-default" :to="editTo">Edit</RouterLink>
      <button class="btn btn-xs btn-info" @click="$router.push('/devices/diag/' + row.deveui)">Diag</button>
      <button class="btn btn-xs btn-danger" @click="deleteRow">Delete</button>
    </template>
  </EntityList>
</template>
```

## EntityForm

File: `src/components/admin/EntityForm.vue`

Props:
- `entity: string` (required)
- `mode: 'create' | 'edit'` (required)
- `recordId?: string`
- `definition?: object`
- `allowAddField?: boolean`
- `redirectAfterCreate?: boolean`

Events:
- `loaded(record)`
- `load-error(message)`
- `submit-success(payload)`
- `submit-error(message)`

Slots:
- `header-actions`
- `before-fields`
- `field`
- `after-fields`
- `extra-actions`

### Defining Entity Form Sections (Tabs)

Define tabs in `src/models/entity-definitions.js` with `formSections`:

```js
config: {
  // ...
  formSections: {
    edit: [
      { id: 'general', labelKey: 'section.general', fields: ['admin_url', 'items_per_page'] },
      { id: 'email', labelKey: 'section.email', fields: ['email_from', 'email_server'] }
    ]
  }
}
```

Notes:
- `create` and `edit` can have different section sets.
- Any fields not assigned to a section are automatically placed into an `Other` tab.
- Labels use `labelKey` (i18n), with `label` as fallback.

Example:

```vue
<script setup>
import EntityForm from '@/components/admin/EntityForm.vue';
</script>

<template>
  <EntityForm entity="devices" mode="edit" :record-id="$route.params.id">
    <template #after-fields>
      <div class="form-group">
        <label class="col-sm-2 control-label">Diagnostics</label>
        <div class="col-sm-10">
          <button type="button" class="btn btn-default">Run Test</button>
        </div>
      </div>
    </template>

    <template #extra-actions="{ saving }">
      <button type="button" class="btn btn-default" :disabled="saving">Validate</button>
    </template>
  </EntityForm>
</template>
```

## Default Wrappers

- `src/views/EntityListView.vue` is a thin wrapper around `EntityList`.
- `src/views/EntityFormView.vue` is a thin wrapper around `EntityForm`.

You can keep existing generic routes and add custom routes/components for entity-specific behavior.
