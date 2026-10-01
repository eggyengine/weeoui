// The Pages workflow sets SITE_URL and BASE_PATH from actions/configure-pages,
// so a custom domain works without editing this file.
const baseUrl = `${process.env.BASE_PATH ?? '/weeoui'}/`.replace(/\/+$/, '/');

/** @type {import('@docusaurus/types').Config} */
export default {
  title: 'Weeoui',
  tagline: 'Immediate-mode UI for Zig',
  url: process.env.SITE_URL ?? 'https://eggyengine.github.io',
  baseUrl,
  onBrokenLinks: 'throw',
  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: '/',
          editUrl: 'https://github.com/eggyengine/weeoui/edit/main/docs/',
        },
        blog: false,
      },
    ],
  ],
  themeConfig: {
    colorMode: { respectPrefersColorScheme: true },
    navbar: {
      title: 'Weeoui',
      items: [
        { to: '/', label: 'Guide', position: 'left' },
        // Zig's generated docs are copied to build/api by the workflow.
        { to: 'pathname:///api/', label: 'API reference', position: 'left' },
        { href: 'https://github.com/eggyengine/weeoui', label: 'GitHub', position: 'right' },
      ],
    },
    prism: { additionalLanguages: ['zig', 'bash'] },
  },
};
