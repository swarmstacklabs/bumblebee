import { defineStore } from 'pinia';
import { listRecords } from '../services/admin-api';

const EVENTS_ENTITY = 'events';
const FETCH_PAGE_SIZE = 30;

export const useEventsStore = defineStore('events', {
  state: () => ({
    events: [],
    loading: false,
    error: ''
  }),
  actions: {
    async fetchEvents(options = {}) {
      this.loading = true;
      this.error = '';

      try {
        const page = Number(options.page) > 0 ? Number(options.page) : 1;
        const perPage = Number(options.perPage) > 0 ? Number(options.perPage) : FETCH_PAGE_SIZE;
        const sortField = String(options.sortField || 'last_rx');
        const sortDir = String(options.sortDir || 'DESC').toUpperCase() === 'ASC' ? 'ASC' : 'DESC';

        const { data } = await listRecords(EVENTS_ENTITY, {
          page,
          page_size: perPage,
          sort_by: sortField,
          sort_order: sortDir
        });
        this.events = Array.isArray(data) ? data : [];
        return this.events;
      } catch (err) {
        this.error = err instanceof Error ? err.message : String(err);
        throw err;
      } finally {
        this.loading = false;
      }
    }
  }
});
