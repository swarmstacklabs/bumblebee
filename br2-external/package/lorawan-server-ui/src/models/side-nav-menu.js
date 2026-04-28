export const sideNavMenu = [
  {
    id: 'server',
    label: 'Server',
    icon: 'fa-server',
    children: [
      { id: 'users', label: 'Users', icon: 'fa-user', to: '/users/list' },
      { id: 'servers', label: 'Servers', icon: 'fa-desktop', to: '/servers/list' },
      { id: 'config', label: 'Configuration', icon: 'fa-cog', to: '/config/edit/main' },
      { id: 'events', label: 'Events', icon: 'fa-exclamation-triangle', to: '/events/list' }
    ]
  },
  {
    id: 'infrastructure',
    label: 'Infrastructure',
    icon: 'fa-sitemap',
    children: [
      { id: 'areas', label: 'Areas', icon: 'fa-street-view', to: '/areas/list' },
      { id: 'gateways', label: 'Gateways', icon: 'fa-wifi', to: '/gateways/list' },
      { id: 'networks', label: 'Networks', icon: 'fa-cloud', to: '/networks/list' },
      {
        id: 'multicast_channels',
        label: 'Multicast Channels',
        icon: 'fa-bullhorn',
        to: '/multicast_channels/list'
      }
    ]
  },
  {
    id: 'devices',
    label: 'Devices',
    icon: 'fa-cubes',
    children: [
      { id: 'groups', label: 'Groups', icon: 'fa-th', to: '/groups/list' },
      { id: 'profiles', label: 'Profiles', icon: 'fa-pencil-square-o', to: '/profiles/list' },
      { id: 'devices', label: 'Commissioned', icon: 'fa-cube', to: '/devices/list' },
      { id: 'nodes', label: 'Activated (Nodes)', icon: 'fa-rss', to: '/nodes/list' },
      { id: 'ignored_nodes', label: 'Ignored', icon: 'fa-ban', to: '/ignored_nodes/list' }
    ]
  },
  {
    id: 'backends',
    label: 'Backends',
    icon: 'fa-industry',
    children: [
      { id: 'handlers', label: 'Handlers', icon: 'fa-cogs', to: '/handlers/list' },
      { id: 'connectors', label: 'Connectors', icon: 'fa-bolt', to: '/connectors/list' }
    ]
  },
  {
    id: 'frames',
    label: 'Frames',
    icon: 'fa-comments',
    to: '/rxframes/list'
  }
];
