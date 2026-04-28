<template>
  <div class="navbar-default sidebar" role="navigation">
    <div class="sidebar-nav navbar-collapse sidebar-collapse">
      <ul id="side-menu" class="nav">
        <li v-for="item in sideNavMenu" :key="item.id" class="entities-repeat">
          <template v-if="item.children">
            <a
              :class="{ active: isSectionActive(item) }"
              href="#"
              @click.prevent="toggleSection(item.id)"
            >
              <span :class="['fa', item.icon, 'fa-fw']" /> {{ item.label }}
              <span
                :class="[
                  'glyphicon',
                  'arrow',
                  isSectionOpen(item.id) ? 'glyphicon-menu-down' : 'glyphicon-menu-right'
                ]"
              />
            </a>

            <ul
              :class="[
                'nav',
                'nav-second-level',
                !isSectionOpen(item.id) ? 'collapsible collapsed' : ''
              ]"
              v-show="isSectionOpen(item.id)"
            >
              <li v-for="child in item.children" :key="child.id">
                <RouterLink :to="child.to" @click="emitNavigate">
                  <span :class="['fa', child.icon, 'fa-fw']" /> {{ child.label }}
                </RouterLink>
              </li>
            </ul>
          </template>

          <RouterLink v-else :to="item.to" @click="emitNavigate">
            <span :class="['fa', item.icon, 'fa-fw']" /> {{ item.label }}
          </RouterLink>
        </li>
      </ul>
    </div>
  </div>
</template>

<script setup>
import { ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { sideNavMenu } from '../models/side-nav-menu';

const emit = defineEmits(['navigate']);
const route = useRoute();

const findParentByRoute = (path) =>
  sideNavMenu.find((item) => item.children?.some((child) => path.startsWith(child.to)));

const initialActiveParent = findParentByRoute(route.path);
const openSectionId = ref(initialActiveParent?.id ?? sideNavMenu.find((item) => item.children)?.id ?? null);

const isSectionOpen = (sectionId) => openSectionId.value === sectionId;

const isSectionActive = (item) =>
  isSectionOpen(item.id) ||
  item.children?.some((child) => route.path.startsWith(child.to));

const toggleSection = (sectionId) => {
  openSectionId.value = openSectionId.value === sectionId ? null : sectionId;
};

const emitNavigate = () => {
  emit('navigate');
};

watch(
  () => route.path,
  (path) => {
    const activeParent = findParentByRoute(path);
    if (activeParent) {
      openSectionId.value = activeParent.id;
    }
  }
);
</script>
