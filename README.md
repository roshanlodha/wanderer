## TODO
- [ ] implement notifications on iOS
    - [ ] check in notification
- [ ] widget + live activities thing
- [ ] fix MLX parsing for emails
- [ ] 

## Local MLX Setup (TripBuddy)

TripBuddy's `Local (MLX)` mode now uses SwiftLM's native OpenAI-compatible endpoint.

1. Clone and build SwiftLM:

```bash
git clone --recursive https://github.com/SharpAI/SwiftLM
cd SwiftLM
./build.sh
```

2. Run SwiftLM with Qwen3.5-4B:

```bash
.build/release/SwiftLM --model mlx-community/Qwen3.5-4B-Instruct-4bit --port 5413
```

3. In TripBuddy Settings:

- Set extraction and/or classification engine to `Local (MLX)`
- Server URL: `http://127.0.0.1:5413`
- Model: `mlx-community/Qwen3.5-4B-Instruct-4bit`

## On-Device MLX (No Local Server)

TripBuddy now supports a user-confirmed on-device model download flow for `Local (MLX)`:

1. Open Settings.
2. Select `Local (MLX)` for extraction/classification.
3. Confirm the download prompt.
4. The app downloads the selected Hugging Face model files to Application Support.
5. Enable `Prefer On-Device Model`.

Notes:
- This avoids requiring a local server for basic on-device parsing.
- If on-device mode is disabled, the app can still use an optional SwiftLM server fallback.

## Prepackaging vs Lightweight Models

Prepackaging a 4B model directly in the app bundle is usually not practical for App Store distribution due to binary size.

Recommended approach:
- Ship the app without model weights.
- Ask user consent before download (already implemented).
- Offer a smaller default model for lower storage/RAM devices, e.g. 0.5B-1.5B MLX variants.

If you still want to prepackage:
1. Add model files under app resources (large app size impact).
2. Copy bundled model directory into Application Support on first launch.
3. Point `localMLXModel` to that local folder name/path convention used by your inference layer.