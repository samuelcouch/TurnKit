# Media Analysis Smoke Test

This example verifies TurnKit's first-class media-analysis path with RubyLLM and
Gemini 3.8 Flash.

It uses RubyLLM's Gemini provider model id from the available-models table:
`gemini-3.8-flash`. That model is listed with text, image, video, audio,
and PDF input support plus structured output.

It exercises:

- `Turn#view_media`
- `TurnKit::Client#view_media`
- `TurnKit::MediaInput`
- `TurnKit::MediaAnalysisResult`
- structured output
- media-analysis message persistence
- usage/cost/event plumbing

Run it with a Gemini API key:

```sh
export GEMINI_API_KEY=...
ruby examples/media_analysis/gemini_3_flash_view_media.rb
```

By default, the example sends a tiny in-memory PNG so no fixture file is needed.
To analyze your own image, PDF, audio file, video file, or URL, pass it as the
first argument:

```sh
ruby examples/media_analysis/gemini_3_flash_view_media.rb /path/to/header.png
ruby examples/media_analysis/gemini_3_flash_view_media.rb https://example.com/report.pdf
```

Override the model if needed:

```sh
TURNKIT_MEDIA_MODEL=gemini-flash-latest ruby examples/media_analysis/gemini_3_flash_view_media.rb
```
