# Multimodal Open-Source Stack

Optimal Engine is local-first and self-hostable. Multimodal support should
therefore be built around open-source tools that can run locally, while still
allowing hosted adapters when a deployment chooses them.

This page defines the public adapter targets. It does not mean every runtime is
installed by default. The engine should preserve raw evidence first, then route
assets through the best configured local adapter for the modality.

## Core Rule

```text
Raw asset
  -> Source Package
  -> governed Asset row
  -> parser / model adapter
  -> extracted text, structure, transcript, visual facts, embeddings
  -> derived Source Package + pending Claim
  -> Facts / Memory Objects only when reviewed
```

The raw asset remains the evidence. Extracted text, OCR, transcripts, visual
captions, page embeddings, summaries, and model outputs are derived artifacts.

## Adapter Targets

| Capability | Primary targets | Engine use |
| --- | --- | --- |
| Document intelligence | Docling, Marker, olmOCR, Unstructured | PDF/Office/image document parsing, layout, tables, OCR, markdown/JSON export. |
| OCR fallback | Tesseract OCR | Conservative local fallback when richer document intelligence is unavailable. |
| Audio transcription | whisper.cpp, Whisper | Speech-to-text for audio files and extracted video audio. |
| Video processing | FFmpeg | Frame extraction, audio extraction, metadata, transcoding. |
| Visual reasoning | Qwen VL | Image/video/document question answering, visual text reading, localization, and reasoning. |
| Visual document retrieval | ColPali / ColQwen | Page-image retrieval when text extraction alone is not enough. |
| Image-text embeddings | OpenCLIP / SigLIP-style adapters | Cross-modal image/text search and zero-shot tagging. |
| Broad cross-modal embeddings | ImageBind-style adapters | Joint retrieval across image, text, audio, and video-derived signals. |

The code-level registry lives at:

```text
lib/optimal_engine/pipeline/multimodal_tool_registry.ex
```

## Recommended Pipelines

### Documents

```text
Source Package
  -> AssetStore
  -> Docling first
  -> Marker / olmOCR / Unstructured fallback or specialist pass
  -> Tesseract fallback for OCR
  -> optional ColPali page retrieval
  -> structured elements, extracted text, images, tables
```

Docling is the default router because it covers multiple formats, local
execution, OCR, advanced PDF layout, exports, audio support, VLM support, and
agent integrations. Marker is valuable for high-accuracy document-to-markdown
and JSON. olmOCR is valuable for scanned and image-based document linearization.
Unstructured remains useful as an ingestion/pre-processing adapter, but its own
documentation calls out limits for the open-source library in production use.

### Images

```text
Source Package
  -> AssetStore
  -> OCR pass when text may exist
  -> Qwen VL visual reasoning when configured
  -> OpenCLIP / ImageBind embedding
  -> Claims only when extraction output is reviewed or policy-accepted
```

Images should not become truth just because a model captioned them. Captions,
OCR, classifications, and visual answers are derived outputs linked to the raw
asset.

### Audio

```text
Source Package
  -> AssetStore
  -> whisper.cpp or Whisper transcript
  -> speaker/time metadata when available
  -> transcript chunks
  -> Claims / Facts / Memory Objects through the normal review lifecycle
```

Transcripts are useful derived evidence, but the audio file remains the preserved
source.

### Video

```text
Source Package
  -> AssetStore
  -> FFmpeg demux
  -> audio transcript
  -> frame/keyframe assets
  -> Qwen VL or embedding pass when configured
  -> episode/workflow extraction when relevant
```

Video becomes a bundle of governed derived artifacts: transcript, keyframes,
frame captions, object/text observations, and timing metadata.

## Storage Shape

The current public backend already supports:

```text
source_packages
assets
asset_adapter_runs
derivation_ledger
parser-produced asset metadata
workspace-scoped indexer ingestion
```

`asset_adapter_runs` records:

```text
adapter_id
adapter_role
modality
status
input_hash
output_hash
output_text / output_ref
model_id / model_version
confidence / precision
security_labels / partition_ids
derivation_ledger_id
```

Future adapter-specific projections can hang off that spine:

```text
asset_extractions
asset_transcripts
asset_ocr_spans
asset_visual_observations
asset_embedding_refs
```

Those rows should include:

```text
workspace_id
source_package_id
asset_id
adapter_id
adapter_version
model_id / model_version when applicable
input_hash
output_hash
confidence
precision
created_by
policy_version
derivation_ledger_id
```

Completed adapter outputs can already enter the truth lifecycle through:

```text
MemoryCore.claim_from_asset_adapter_run(run_id, opts)
```

That bridge preserves the adapter output as a derived Source Package and creates
a pending Claim. It does not automatically promote the model output to a Fact.

## Deployment

Docker is optional. Local development can run with SQLite and whichever binaries
are available on the machine. Production deployments can package the selected
adapters in Docker or another process manager.

The engine should ask the registry what is configured and available:

```text
MultimodalToolRegistry.recommended_pipeline(:document)
MultimodalToolRegistry.availability()
MemoryCore.run_asset_adapter(asset_id, :docling, command: "docling")
```

Missing binaries should degrade gracefully. The engine should preserve the raw
asset, write a warning or adapter-run failure, and continue the rest of the
pipeline where possible.

## Primary References

- Docling: <https://github.com/docling-project/docling>
- Marker: <https://github.com/datalab-to/marker>
- olmOCR: <https://github.com/allenai/olmocr>
- Unstructured open source: <https://docs.unstructured.io/open-source/introduction/overview>
- Whisper: <https://github.com/openai/whisper>
- whisper.cpp: <https://github.com/ggml-org/whisper.cpp>
- Qwen VL: <https://github.com/QwenLM/Qwen3-VL>
- ColPali / ColQwen: <https://github.com/illuin-tech/colpali>
- OpenCLIP: <https://github.com/mlfoundations/open_clip>
- ImageBind: <https://github.com/facebookresearch/ImageBind>
