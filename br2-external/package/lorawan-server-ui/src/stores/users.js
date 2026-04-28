import { createCrudEntityStore } from './create-crud-entity-store';

export const useUsersStore = createCrudEntityStore({
  storeId: 'users',
  entity: 'users',
  idField: 'name'
});
