<script lang="ts">
  import PagesGraph from '$lib/knowledge/PagesGraph.svelte';
  import type { GNode } from '$lib/knowledge/graph';
  import { activeWorkspaceId } from '$lib/stores/workspace';

  let selected = $state<GNode | null>(null);

  function onSelect(n: GNode) {
    selected = n;
  }
</script>

<div class="graph-page">
  {#key $activeWorkspaceId}
    <PagesGraph {onSelect} />
  {/key}
</div>

<style>
  .graph-page {
    position: relative;
    width: 100%;
    height: 100%;
  }
</style>
