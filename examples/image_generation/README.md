# Image Generation Smoke Test

This example verifies TurnKit's first-class image path with the local
`generate-image` CLI and its `nano-banana-pro` alias for Gemini's
`gemini-3-pro-image-preview` model.

It exercises:

- `Turn#paint`
- `TurnKit::Client#paint`
- `TurnKit::ImageResult`
- image message persistence
- usage/cost/event plumbing

Run it with a Gemini-capable image CLI configuration:

```sh
ruby examples/image_generation/nano_banana_16x9.rb
```

Or choose the output path:

```sh
ruby examples/image_generation/nano_banana_16x9.rb /tmp/header.jpg
```

The example calls:

```sh
generate-image \
  --provider gemini \
  --model nano-banana-pro \
  --aspect-ratio 16:9 \
  --image-size 1K
```

It writes the generated image to `/tmp/turnkit-nano-banana-pro-16x9.jpg` by
default so generated binaries are not added to the repository.
