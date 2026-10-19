<script lang="ts">
  import type { EngineContext } from '../engine.js';
  import type { GrepHit, GrepScale } from '@optimal-engine/client';

  /**
   * What `onselect` receives. A grep hit is a chunk of a node, so the payload
   * names the node (`slug`) and the chunk's scale and intent.
   */
  interface SelectPayload {
    type: 'node';
    slug: string;
    scale: GrepScale;
    intent: string | null;
  }

  interface Props {
    engine: EngineContext;
    open?: boolean;
    onclose?: () => void;
    onselect?: (payload: SelectPayload) => void;
  }

  let { engine, open = false, onclose, onselect }: Props = $props();

  let query = $state('');
  let results = $state<GrepHit[]>([]);
  let loading = $state(false);
  let activeIndex = $state(-1);
  let debounceTimer: ReturnType<typeof setTimeout> | null = null;

  $effect(() => {
    if (!open) {
      query = '';
      results = [];
      activeIndex = -1;
    }
  });

  function onInput(e: Event) {
    query = (e.target as HTMLInputElement).value;
    activeIndex = -1;
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => void search(), 200);
  }

  async function search() {
    if (!query.trim()) {
      results = [];
      return;
    }
    loading = true;
    try {
      const ws = engine.getWorkspace();
      const raw = await engine.client.grep(query, { workspace: ws, limit: 15 });
      results = raw.results;
    } catch {
      // Silently suppress: palette search errors shouldn't crash the UI
    } finally {
      loading = false;
    }
  }

  function selectItem(hit: GrepHit) {
    onselect?.({ type: 'node', slug: hit.slug, scale: hit.scale, intent: hit.intent });
    onclose?.();
  }

  function onKeydown(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === 'Escape') { onclose?.(); return; }
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      activeIndex = Math.min(activeIndex + 1, results.length - 1);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      activeIndex = Math.max(activeIndex - 1, 0);
    } else if (e.key === 'Enter' && activeIndex >= 0) {
      e.preventDefault();
      const hit = results[activeIndex];
      if (hit) selectItem(hit);
    }
  }

  function scoreLevel(score: number): 'high' | 'mid' | 'low' {
    return score >= 0.7 ? 'high' : score >= 0.4 ? 'mid' : 'low';
  }

  function scorePct(score: number): number {
    return Math.min(100, Math.max(0, Math.round(score * 100)));
  }
</script>

<svelte:window onkeydown={onKeydown} />

{#if open}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="oe-palette-overlay" onclick={onclose} role="dialog" aria-modal="true" aria-label="Search palette">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="oe-palette" onclick={(e) => e.stopPropagation()} role="presentation">
      <!-- Input row -->
      <div class="oe-palette__input-row">
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true" style="color: var(--dt4, #555); flex-shrink: 0;">
          <circle cx="7" cy="7" r="5" stroke="currentColor" stroke-width="1.5"/>
          <path d="M11 11l3 3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
        </svg>
        <input
          class="oe-palette__input"
          type="text"
          placeholder="Search this workspace…"
          value={query}
          oninput={onInput}
          autofocus
          aria-label="Search"
          aria-autocomplete="list"
          role="combobox"
          aria-expanded={results.length > 0}
        />
        {#if loading}
          <div class="oe-spinner sp-spinner"></div>
        {/if}
      </div>

      <!-- Results -->
      <div class="oe-palette__results" role="listbox">
        {#if !query.trim() && results.length === 0}
          <div class="sp-hint">Type to search this workspace.</div>
        {:else if query.trim() && results.length === 0 && !loading}
          <div class="sp-hint">No results for "{query}"</div>
        {:else}
          <div class="oe-palette__section-label">Matches</div>
          {#each results as hit, idx}
            {@const isActive = activeIndex === idx}
            {@const slvl = scoreLevel(hit.score)}
            <!-- svelte-ignore a11y_click_events_have_key_events -->
            <!-- svelte-ignore a11y_no_static_element_interactions -->
            <div
              class="oe-palette__result {isActive ? 'oe-palette__result--active' : ''}"
              role="option"
              aria-selected={isActive}
              onclick={() => selectItem(hit)}
            >
              <div class="sp-result-body">
                <div class="oe-palette__result-title">{hit.slug}</div>
                <div class="oe-palette__result-snippet">{hit.snippet}</div>
              </div>
              <div class="sp-result-right">
                <span class="oe-chip sp-type-chip sp-chip-scale">{hit.scale}</span>
                {#if hit.intent}
                  <span class="oe-chip sp-type-chip sp-chip-intent">{hit.intent}</span>
                {/if}
                <div class="oe-score-bar sp-score">
                  <div class="oe-score-bar__track">
                    <div class="oe-score-bar__fill oe-score-bar__fill--{slvl}" style="width: {scorePct(hit.score)}%"></div>
                  </div>
                </div>
              </div>
            </div>
          {/each}
        {/if}
      </div>

      <!-- Footer hints -->
      <div class="oe-palette__footer">
        <span><kbd class="oe-palette__kbd">↑↓</kbd> navigate</span>
        <span><kbd class="oe-palette__kbd">↵</kbd> select</span>
        <span><kbd class="oe-palette__kbd">esc</kbd> close</span>
      </div>
    </div>
  </div>
{/if}

<style>
  .sp-spinner {
    width: 16px;
    height: 16px;
    flex-shrink: 0;
  }

  .sp-hint {
    padding: 1rem;
    text-align: center;
    font-size: 0.84rem;
    color: var(--dt4, #555);
  }

  .sp-result-body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
  }

  .sp-result-right {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 0.3rem;
    flex-shrink: 0;
  }

  .sp-score {
    width: 60px;
  }

  .sp-type-chip {
    font-size: 0.6rem;
    padding: 1px 5px;
  }

  .sp-chip-scale {
    background: rgba(126, 168, 255, 0.1);
    color: var(--daccent, #7ea8ff);
    border: 1px solid rgba(126, 168, 255, 0.2);
  }

  .sp-chip-intent {
    background: rgba(187, 126, 255, 0.1);
    color: #bb7eff;
    border: 1px solid rgba(187, 126, 255, 0.2);
  }
</style>
