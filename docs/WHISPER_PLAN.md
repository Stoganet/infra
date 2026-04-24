# Whisper Subtitle Generation Plan

Automated subtitle generation for missing subtitles using OpenAI Whisper large-v3,
running on the Mac M4 Pro and integrated into Bazarr as an on-demand provider.

## Overview

The homeserver's i5-5300U is too slow for practical Whisper transcription. The Mac M4 Pro
(48GB RAM) runs large-v3 at ~5-10 min per 45-min episode via Docker CPU mode — fast enough
to clear the entire backlog in one session. Bazarr natively supports the whisper-asr-webservice
API format, so no custom code is needed.

Current missing subtitle backlog (as of 2026-04-24):
- 238 episodes missing subs (fi=131, pt=153, fr=62, en=0)
- 3 movies missing subs

## Mac Setup (one-time)

Run once in Terminal on the Mac to create the container:

```bash
docker run -d \
  --name whisper \
  --restart no \
  -p 9000:9000 \
  -e ASR_MODEL=large-v3 \
  onerahmet/openai-whisper-asr-webservice:latest-cpu
```

- `--restart no` keeps it manual — only runs when you start it
- First run downloads the large-v3 model (~3GB), subsequent starts are instant
- ARM64-native image, runs on Apple Silicon without emulation

Add aliases to `~/.zshrc` for easy control:

```bash
alias whisper-on="docker start whisper && echo 'Whisper running on port 9000'"
alias whisper-off="docker stop whisper && echo 'Whisper stopped'"
```

Find Mac's LAN IP (needed for Bazarr config below):

```bash
ipconfig getifaddr en0
```

Set a DHCP reservation for the Mac on the router so the IP doesn't change.

## Server Setup (Bazarr config)

Edit Bazarr's config inside the container at `/config/config/config.yaml`:

```bash
docker cp bazarr:/config/config/config.yaml /tmp/bazarr_config.yaml
# edit /tmp/bazarr_config.yaml
docker cp /tmp/bazarr_config.yaml bazarr:/config/config/config.yaml
docker compose restart bazarr
```

Changes needed in `config.yaml`:

```yaml
general:
  enabled_providers:
  - opensubtitlescom
  - podnapisi
  - soustitreseu
  - subsource
  - subdl
  - legendasnet
  - whisperai          # add this

whisperai:
  endpoint: http://<MAC_LAN_IP>:9000   # replace with actual IP
  loglevel: INFO
  pass_video_name: false
  response: 5
  timeout: 3600
```

Whisper should be last in the provider list — Bazarr tries providers in order,
so internet sources are preferred. Whisper only kicks in for anything they can't cover.

## Workflow

**To clear the missing subtitle backlog:**
1. `whisper-on` on Mac
2. Bazarr automatically detects the provider and starts processing the wanted queue
3. Walk away — check progress in Bazarr UI → History
4. `whisper-off` when done (or leave running until it finishes)

**To re-do subtitles for ALL media** (optional quality pass):
1. In Bazarr UI → Movies → select all → Search Subtitles
2. In Bazarr UI → Series → select all → Search Subtitles
3. Bazarr will compare scores; Whisper replaces existing subs only if it scores higher
4. Useful for shows where downloaded subs had sync/quality issues

## Notes

- Whisper does NOT use the Mac's Metal GPU through Docker — CPU only
  Native Metal would require a custom Python server with mlx-whisper or whisper.cpp
  Even CPU mode on M4 Pro is ~5x faster than the homeserver's i5
- Finnish subtitle quality: `large-v3` handles Finnish well, better than `small`
- The Mac doesn't need to be on 24/7 — Bazarr falls back gracefully when
  the whisper endpoint is unreachable and retries when it comes back
- Bazarr's adaptive searching (3-week delay) still applies to Whisper-generated subs

## Future Improvement: Native Metal (optional)

For ~3x more speed than Docker CPU, replace the Docker container with a native
Python server using `mlx-whisper` (Apple MLX framework, uses Neural Engine):

```bash
pip3 install mlx-whisper flask
```

Requires a small Flask/FastAPI wrapper to expose the `/asr` endpoint format
that Bazarr expects. Worth doing if the Docker approach feels too slow.
