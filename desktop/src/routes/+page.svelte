<script lang="ts">
  import { ask, type RagResult } from '$lib/api';

  let query = '';
  let audience = 'default';
  let loading = false;
  let result: RagResult | null = null;
  let error: string | null = null;

  async function submit() {
    if (!query.trim()) return;
    loading = true;
    error = null;
    result = null;

    try {
      result = await ask(query, { audience, format: 'markdown' });
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }
</script>

<section>
  <h2>Ask</h2>

  <form on:submit|preventDefault={submit}>
    <input
      type="text"
      bind:value={query}
      placeholder="Q4 pricing decision"
      disabled={loading}
      autofocus
    />
    <select bind:value={audience} disabled={loading}>
      <option value="default">default</option>
      <option value="sales">sales</option>
      <option value="legal">legal</option>
      <option value="exec">exec</option>
    </select>
    <button type="submit" disabled={loading || !query.trim()}>
      {loading ? 'Thinking…' : 'Ask'}
    </button>
  </form>

  {#if error}
    <pre class="error">{error}</pre>
  {/if}

  {#if result}
    <div class="trace">
      source: <code>{result.source}</code> &middot;
      candidates: <code>{result.trace.n_candidates}</code> &middot;
      delivered: <code>{result.trace.n_delivered}</code> &middot;
      elapsed: <code>{result.trace.elapsed_ms}ms</code>
    </div>

    <pre class="envelope">{result.envelope.body}</pre>

    {#if result.envelope.sources.length > 0}
      <h3>Sources</h3>
      <ul>
        {#each result.envelope.sources as uri}
          <li><code>{uri}</code></li>
        {/each}
      </ul>
    {/if}
  {/if}
</section>

<style>
  h2 {
    color: #ccc;
    margin-top: 0;
  }
  form {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 1rem;
  }
  input[type='text'] {
    flex: 1;
    background: #111;
    color: #eee;
    border: 1px solid #333;
    border-radius: 4px;
    padding: 0.5rem 0.75rem;
    font-size: 0.95rem;
  }
  select,
  button {
    background: #111;
    color: #eee;
    border: 1px solid #333;
    border-radius: 4px;
    padding: 0.5rem 0.75rem;
    font-size: 0.95rem;
  }
  button:disabled {
    opacity: 0.5;
  }
  .trace {
    color: #888;
    font-size: 0.8rem;
    margin-bottom: 0.5rem;
  }
  .trace code {
    color: #cdf;
  }
  .envelope {
    background: #0e1116;
    border: 1px solid #222;
    border-radius: 4px;
    padding: 1rem;
    white-space: pre-wrap;
    font-family: 'SF Mono', Menlo, monospace;
    font-size: 0.88rem;
    line-height: 1.5;
  }
  .error {
    color: #f88;
    background: #311;
    padding: 0.5rem;
    border-radius: 4px;
  }
  ul {
    list-style: none;
    padding: 0;
  }
  li {
    padding: 0.25rem 0;
    color: #8af;
  }
</style>
