import { defineStore } from 'pinia';
import { listRecords } from '../services/admin-api';

const SERVERS_ENTITY = 'servers';
const FETCH_PAGE_SIZE = 30;

export const useServersStore = defineStore('servers', {
  state: () => ({
    servers: [],
    loading: false,
    error: ''
  }),
  actions: {
    async fetchServers(options = {}) {
      this.loading = true;
      this.error = '';

      try {
        const sortField = String(options.sortField || '');
        const sortDir = String(options.sortDir || 'ASC').toUpperCase() === 'DESC' ? 'DESC' : 'ASC';
        let page = 1;
        let total = Number.POSITIVE_INFINITY;
        const collected = [];

        while (collected.length < total) {
          const params = {
            page,
            page_size: FETCH_PAGE_SIZE
          };
          if (sortField) {
            params.sort_by = sortField;
            params.sort_order = sortDir;
          }

          const { data, headers } = await listRecords(SERVERS_ENTITY, params);

          const chunk = Array.isArray(data) ? data : [];
          collected.push(...chunk);

          const totalFromHeader = Number(headers.get('x-total-count') || collected.length);
          total = Number.isFinite(totalFromHeader) ? totalFromHeader : collected.length;

          if (chunk.length === 0 || chunk.length < FETCH_PAGE_SIZE) {
            break;
          }

          page += 1;
        }

        this.servers = collected;
        return this.servers;
      } catch (err) {
        this.error = err instanceof Error ? err.message : String(err);
        throw err;
      } finally {
        this.loading = false;
      }
    }
  }
});
