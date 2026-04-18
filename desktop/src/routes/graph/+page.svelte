<script lang="ts">
  import { onMount } from 'svelte';
  import OptimalGraphView from '$lib/components/knowledge/OptimalGraphView.svelte';
  import NodeDrillDown from '$lib/components/knowledge/NodeDrillDown.svelte';

  interface NodeInfo {
    slug: string;
    name: string;
    type: string;
    signal_count: number;
  }

  let nodes = $state<NodeInfo[]>([]);
  let selectedEntity = $state<{ name: string; type: string } | null>(null);
  let drillOpen = $state(false);

  onMount(async () => {
    try {
      const res = await fetch('/api/optimal/nodes');
      if (res.ok) {
        const data = await res.json();
        nodes = data.nodes ?? [];
      }
    } catch {
      nodes = [];
    }
  });

  function onSelectEntity(name: string, type: string) {
    selectedEntity = { name, type };
    drillOpen = true;
  }

  function closeDrill() {
    selectedEntity = null;
    drillOpen = false;
  }

  function handleOpenFile(path: string) {
    // Future: route to a signal detail page. For now, log so the component
    // contract is observable during development.
    console.log('[graph] open file:', path);
  }
</script>

<div class="graph-page">
  <div class="graph-page__main">
    <OptimalGraphView {onSelectEntity} />
  </div>

  {#if drillOpen}
    <aside class="graph-page__drill">
      <header>
        {#if selectedEntity}
          <h3>{selectedEntity.name}</h3>
          <span class="type">{selectedEntity.type}</span>
        {:else}
          <h3>Browse</h3>
        {/if}
        <button onclick={closeDrill} aria-label="Close">×</button>
      </header>
      <div class="graph-page__drill-body">
        <NodeDrillDown {nodes} onOpenFile={handleOpenFile} />
      </div>
    </aside>
  {:else}
    <button class="graph-page__drill-toggle" onclick={() => (drillOpen = true)}>
      Browse nodes
    </button>
  {/if}
</div>

<style>
  .graph-page {
    display: flex;
    height: calc(100vh - 64px);
    background: #0b0d10;
    position: relative;
  }
  .graph-page__main {
    flex: 1;
    min-width: 0;
    position: relative;
  }
  .graph-page__drill {
    width: 420px;
    flex-shrink: 0;
    background: #0e1116;
    border-left: 1px solid #222;
    display: flex;
    flex-direction: column;
  }
  .graph-page__drill header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.75rem 1rem;
    border-bottom: 1px solid #222;
  }
  .graph-page__drill h3 {
    flex: 1;
    margin: 0;
    font-size: 0.95rem;
    color: #ddd;
  }
  .type {
    padding: 2px 8px;
    background: #143;
    color: #6f8;
    border-radius: 999px;
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }
  button {
    background: none;
    border: none;
    color: #888;
    font-size: 1.5rem;
    cursor: pointer;
    padding: 0 0.5rem;
    line-height: 1;
  }
  button:hover {
    color: #ccc;
  }
  .graph-page__drill-body {
    flex: 1;
    overflow: auto;
    padding: 0.5rem 0;
  }
  .graph-page__drill-toggle {
    position: absolute;
    top: 1rem;
    right: 1rem;
    padding: 0.5rem 0.75rem;
    font-size: 0.8rem;
    background: #111;
    border: 1px solid #333;
    border-radius: 6px;
    color: #ccc;
  }
</style>
