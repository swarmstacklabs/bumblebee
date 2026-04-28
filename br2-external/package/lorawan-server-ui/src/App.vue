<template>
  <div id="wrapper">
    <nav id="header-nav" class="navbar navbar-default navbar-static-top" role="navigation">
      <span>
        <div class="navbar-header">
          <button
            type="button"
            class="navbar-toggle"
            :aria-expanded="String(isSidebarOpen)"
            @click="toggleSidebar"
          >
            <span class="icon-bar" />
            <span class="icon-bar" />
            <span class="icon-bar" />
          </button>
          <RouterLink class="navbar-brand" to="/dashboard">Server Admin</RouterLink>
        </div>
      </span>

      <SideNav v-show="!isMobileViewport || isSidebarOpen" @navigate="handleNavigate" />
    </nav>

    <div id="page-wrapper">
      <RouterView />
    </div>
  </div>
</template>

<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue';
import SideNav from './components/SideNav.vue';

const MOBILE_WIDTH_MAX = 767;

const isMobileViewport = ref(false);
const isSidebarOpen = ref(true);

const syncViewportState = () => {
  const mobile = window.innerWidth <= MOBILE_WIDTH_MAX;
  const wasMobile = isMobileViewport.value;
  isMobileViewport.value = mobile;

  if (mobile !== wasMobile) {
    isSidebarOpen.value = !mobile;
  }
};

const toggleSidebar = () => {
  if (!isMobileViewport.value) {
    return;
  }
  isSidebarOpen.value = !isSidebarOpen.value;
};

const handleNavigate = () => {
  if (isMobileViewport.value) {
    isSidebarOpen.value = false;
  }
};

onMounted(() => {
  syncViewportState();
  window.addEventListener('resize', syncViewportState);
});

onBeforeUnmount(() => {
  window.removeEventListener('resize', syncViewportState);
});
</script>
