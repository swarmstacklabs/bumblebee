const VIS_SCRIPT_SELECTOR = 'script[data-vis-js="true"]';
const VIS_SCRIPT_SRC = '/admin/vis.min.js';

export const ensureVisScript = () =>
  new Promise((resolve, reject) => {
    if (window.vis) {
      resolve(window.vis);
      return;
    }

    const existing = document.querySelector(VIS_SCRIPT_SELECTOR);
    if (existing) {
      existing.addEventListener('load', () => resolve(window.vis), { once: true });
      existing.addEventListener('error', () => reject(new Error(`Failed to load ${VIS_SCRIPT_SRC}`)), {
        once: true
      });
      return;
    }

    const script = document.createElement('script');
    script.src = VIS_SCRIPT_SRC;
    script.async = true;
    script.dataset.visJs = 'true';
    script.onload = () => resolve(window.vis);
    script.onerror = () => reject(new Error(`Failed to load ${VIS_SCRIPT_SRC}`));
    document.head.appendChild(script);
  });
