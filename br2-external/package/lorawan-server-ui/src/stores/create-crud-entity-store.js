import { defineStore } from 'pinia';
import { createRecord, deleteRecord, listRecords, readRecord, updateRecord } from '../services/admin-api';

const DEFAULT_PAGE_SIZE = 200;

const compareValues = (left, right) => {
  if (left == null && right == null) {
    return 0;
  }
  if (left == null) {
    return -1;
  }
  if (right == null) {
    return 1;
  }
  if (typeof left === 'number' && typeof right === 'number') {
    return left - right;
  }
  return String(left).localeCompare(String(right), undefined, { sensitivity: 'base' });
};

export const createCrudEntityStore = ({ storeId, entity, idField = 'id', fetchPageSize = DEFAULT_PAGE_SIZE }) => {
  const recordIdOf = (record) => String(record?.[idField] ?? '');

  return defineStore(storeId, {
    state: () => ({
      records: [],
      loading: false,
      error: ''
    }),
    getters: {
      byId: (state) => (id) => state.records.find((record) => recordIdOf(record) === String(id || '')) || null
    },
    actions: {
      clearError() {
        this.error = '';
      },
      upsertRecord(record) {
        const id = recordIdOf(record);
        if (!id) {
          return;
        }
        const index = this.records.findIndex((item) => recordIdOf(item) === id);
        if (index === -1) {
          this.records.push(record);
          return;
        }
        this.records[index] = { ...this.records[index], ...record };
      },
      removeRecord(id) {
        this.records = this.records.filter((record) => recordIdOf(record) !== String(id || ''));
      },
      async fetchAll() {
        this.loading = true;
        this.error = '';
        try {
          let page = 1;
          let total = Number.POSITIVE_INFINITY;
          const records = [];

          while (records.length < total) {
            const { data, headers } = await listRecords(entity, {
              page,
              page_size: fetchPageSize
            });
            const chunk = Array.isArray(data) ? data : [];
            records.push(...chunk);

            const totalFromHeader = Number(headers.get('x-total-count') || records.length);
            total = Number.isFinite(totalFromHeader) ? totalFromHeader : records.length;

            if (chunk.length === 0 || chunk.length < fetchPageSize) {
              break;
            }
            page += 1;
          }

          this.records = records;
          return this.records;
        } catch (err) {
          this.error = err instanceof Error ? err.message : String(err);
          throw err;
        } finally {
          this.loading = false;
        }
      },
      async fetchById(id) {
        const cached = this.byId(id);
        if (cached) {
          return cached;
        }

        this.loading = true;
        this.error = '';
        try {
          const { data } = await readRecord(entity, id);
          this.upsertRecord(data || {});
          return data || null;
        } catch (err) {
          this.error = err instanceof Error ? err.message : String(err);
          throw err;
        } finally {
          this.loading = false;
        }
      },
      async createOne(payload) {
        this.loading = true;
        this.error = '';
        try {
          const result = await createRecord(entity, payload);
          const created = result?.data || payload || {};
          this.upsertRecord(created);
          return result;
        } catch (err) {
          this.error = err instanceof Error ? err.message : String(err);
          throw err;
        } finally {
          this.loading = false;
        }
      },
      async updateOne(id, payload) {
        this.loading = true;
        this.error = '';
        try {
          const result = await updateRecord(entity, id, payload);
          const updated = result?.data || { ...payload, [idField]: id };
          this.upsertRecord(updated);
          return result;
        } catch (err) {
          this.error = err instanceof Error ? err.message : String(err);
          throw err;
        } finally {
          this.loading = false;
        }
      },
      async deleteOne(id) {
        this.loading = true;
        this.error = '';
        try {
          const result = await deleteRecord(entity, id);
          this.removeRecord(id);
          return result;
        } catch (err) {
          this.error = err instanceof Error ? err.message : String(err);
          throw err;
        } finally {
          this.loading = false;
        }
      },
      listPage({
        page = 1,
        perPage = 30,
        sortField = '',
        sortDir = 'ASC',
        valueReader = (item, key) => item?.[key]
      } = {}) {
        const ordered = [...this.records];
        if (sortField) {
          ordered.sort((left, right) => {
            const base = compareValues(valueReader(left, sortField), valueReader(right, sortField));
            return sortDir === 'DESC' ? -base : base;
          });
        }

        const currentPage = Math.max(1, Number(page) || 1);
        const size = Math.max(1, Number(perPage) || 30);
        const start = (currentPage - 1) * size;
        return {
          rows: ordered.slice(start, start + size),
          totalCount: ordered.length
        };
      }
    }
  });
};
