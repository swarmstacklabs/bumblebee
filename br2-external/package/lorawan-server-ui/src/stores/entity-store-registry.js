import { useUsersStore } from './users';

const entityStoreFactories = {
  users: useUsersStore
};

export const resolveEntityStore = (entity) => {
  const factory = entityStoreFactories[String(entity || '')];
  return typeof factory === 'function' ? factory() : null;
};

export const registerEntityStore = (entity, useStore) => {
  entityStoreFactories[String(entity || '')] = useStore;
};
