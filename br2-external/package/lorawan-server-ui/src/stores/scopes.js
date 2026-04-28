import { defineStore } from 'pinia';
import { listRecords } from '../services/admin-api';

const SCOPES_ENTITY = 'scopes';
const FETCH_PAGE_SIZE = 200;

const normalizeScope = (item) => {
  if (typeof item === 'string') {
    return item;
  }
  if (item && typeof item === 'object') {
    if (typeof item.scope === 'string') {
      return item.scope;
    }
    if (typeof item.name === 'string') {
      return item.name;
    }
    if (typeof item.id === 'string') {
      return item.id;
    }
  }
  return '';
};

export const useScopesStore = defineStore('scopes', {
  state: () => ({
    scopes: [],
    loading: false,
    error: ''
  }),
  actions: {
    async fetchScopes() {
      if (this.scopes.length > 0) {
        return this.scopes;
      }

      this.loading = true;
      this.error = '';
      try {
        let page = 1;
        let total = Number.POSITIVE_INFINITY;
        const collected = [];

        while (collected.length < total) {
          const { data, headers } = await listRecords(SCOPES_ENTITY, {
            page,
            page_size: FETCH_PAGE_SIZE
          });

          const chunk = Array.isArray(data) ? data : [];
          collected.push(...chunk);

          const totalFromHeader = Number(headers.get('x-total-count') || collected.length);
          total = Number.isFinite(totalFromHeader) ? totalFromHeader : collected.length;

          if (chunk.length === 0 || chunk.length < FETCH_PAGE_SIZE) {
            break;
          }
          page += 1;
        }

        this.scopes = [...new Set(collected.map(normalizeScope).filter(Boolean))].sort((a, b) =>
          a.localeCompare(b, undefined, { sensitivity: 'base' })
        );
        return this.scopes;
      } catch (err) {
        this.error = err instanceof Error ? err.message : String(err);
        throw err;
      } finally {
        this.loading = false;
      }
    }
  }
});
