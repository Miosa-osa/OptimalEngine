<script lang="ts">
  import { onMount } from 'svelte';
  import { status, type StatusPayload } from '$lib/api';

  let engineStatus: StatusPayload['status'] = 'down';

  onMount(async () => {
    try {
      const s = await status();
      engineStatus = s.status;
    } catch {
      engineStatus = 'down';
    }
  });
</script>

<header>
  <h1>Optimal Engine</h1>
  <nav>
    <a href="/">Ask</a>
    <a href="/workspace">Workspace</a>
    <a href="/graph">Graph</a>
    <a href="/wiki">Wiki</a>
    <a href="/architectures">Architectures</a>
    <a href="/activity">Activity</a>
    <a href="/status">Status</a>
  </nav>
  <span class="badge badge-{engineStatus}">{engineStatus}</span>
</header>

<main>
  <slot />
</main>

<style>
  :global(body) {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    color: #eee;
    background: #0b0d10;
  }
  header {
    display: flex;
    align-items: center;
    gap: 1rem;
    padding: 0.75rem 1.25rem;
    border-bottom: 1px solid #222;
  }
  header h1 {
    font-size: 1rem;
    margin: 0;
    color: #ccc;
  }
  nav {
    display: flex;
    gap: 0.75rem;
    flex: 1;
  }
  nav a {
    color: #8af;
    text-decoration: none;
    font-size: 0.9rem;
  }
  nav a:hover {
    color: #cdf;
  }
  .badge {
    padding: 2px 8px;
    border-radius: 999px;
    font-size: 0.75rem;
    font-weight: 600;
  }
  .badge-up {
    background: #143;
    color: #6f8;
  }
  .badge-degraded {
    background: #432;
    color: #fc6;
  }
  .badge-down {
    background: #421;
    color: #f88;
  }
  main {
    padding: 1.5rem;
    max-width: 900px;
    margin: 0 auto;
  }
</style>
