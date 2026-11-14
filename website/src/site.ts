// The brand, the address and the repository, in one place. The app and the repository
// are still called Achtung; when they are renamed, change `repository` here.
export const site = {
  name: "achtunk8s",
  url: "https://achtunk8s.io",
  repository: "https://github.com/stibi/achtung",
  tagline: "Alerts deserve an inbox, not a chat channel.",
  description:
    "achtunk8s is a self-hosted alert inbox for Alertmanager and Kubernetes alerts, with a native macOS app. Every alert keeps its identity and history, and you see at a glance what is new and what is still broken.",
} as const;

/** A file in the repository on GitHub, e.g. `docs/adr/0007-alert-identity-and-history.md`. */
export function repositoryFile(path: string): string {
  return `${site.repository}/blob/main/${path}`;
}
