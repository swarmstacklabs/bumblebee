import { createRouter, createWebHashHistory } from 'vue-router';
import DashboardView from './views/DashboardView.vue';
import EntityListView from './views/EntityListView.vue';
import EntityFormView from './views/EntityFormView.vue';
import TimelineView from './views/TimelineView.vue';

const routes = [
  { path: '/', redirect: '/dashboard' },
  { path: '/dashboard', component: DashboardView },
  { path: '/timeline', component: TimelineView },
  { path: '/:entity/list', component: EntityListView },
  { path: '/:entity/create', component: EntityFormView, props: { mode: 'create' } },
  { path: '/:entity/edit/:id', component: EntityFormView, props: { mode: 'edit' } }
];

export default createRouter({
  history: createWebHashHistory(),
  routes
});
