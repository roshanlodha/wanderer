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