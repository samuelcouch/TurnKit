# Image Generation Smoke Test

This example verifies TurnKit's first-class image path with `gpt-image-2`
through the standard `TurnKit::Adapters::RubyLLM` adapter.

It exercises:

- `Turn#paint`
- `TurnKit::Client#paint`
- `TurnKit::ImageResult`
- image message persistence
- usage/cost/event plumbing

Set an OpenAI API key and run it:

```sh
export OPENAI_API_KEY=...
ruby examples/image_generation/gpt_image_2.rb
```

Or choose the output path:

```sh
ruby examples/image_generation/gpt_image_2.rb /tmp/header.png
```

Override the model when testing another RubyLLM-compatible OpenAI image model:

```sh
TURNKIT_IMAGE_MODEL=my-image-model ruby examples/image_generation/gpt_image_2.rb
```

The example requests PNG output at `1536x1024`, persists the image message and
prints lifecycle events, usage, and cost. It writes the generated image to
`/tmp/turnkit-gpt-image-2.png` by default so generated binaries are not added to
the repository.
