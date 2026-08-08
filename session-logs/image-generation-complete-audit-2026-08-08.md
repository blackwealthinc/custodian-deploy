# Image Generation — Complete Audit & Implementation Plan (2026-08-08)

## Session Summary

Traced image generation end-to-end across Dell (10.0.0.10) and VM205 (192.168.50.205). Fixed Bug #82 (quality: hd → auto — two layers: invalid parameter + timeout). Discovered Bugs #83 (dead path in factory script Step 5e) and #84 (customer key missing models). Completed full audit of key architecture, model routing, storage, and auto-delete requirements.

## Key Findings

### VM205 State
- 3 virtual keys: admin (2 models, $100), custodian (2 models, $100/mo), no-alias (5 models, $50)
- gpt-image-2-hd configured with quality: auto, LiteLLM v1.95.0, PostgreSQL-backed
- Spend tracking active: LiteLLM_SpendLogs table records every API call
- Daily spend: ~$0.01-$0.16/day, total ~$0.48 since July 21

### Dell State
- WebUI v0.11.0, Hermes v2026.7.20
- image_generation config: engine=openai, model=gpt-image-2-hd, url=http://100.64.0.1:4000/v1
- image_generation.openai.api_key: sk-6tc...8OnA (no-alias key — WRONG KEY, see Bug #83)
- Hermes model.api_key: sk-zLD...HHWA (custodian key)
- api_configs: dashscope-vision → custodian key, gpt-image-2-hd → no-alias key
- api_keys[0] → Hermes, api_keys[1] → LiteLLM (same as api_configs)
- Function Calling: Legacy (Native mode tested — DeepSeek-V4-Pro doesn't call tools)
- Images stored locally: uploads/d74f6831-..._generated-image.png (1.57 MB)
- Total disk: 891 MB (889 MB embeddings, ~3 MB uploads)
- 20 total files in uploads/ (2 generated, 18 uploaded screenshots)

### Bugs Discovered
- **#82**: quality: hd → auto (layer 1: 400 invalid parameter, layer 2: 408 timeout)
- **#83**: Dead path in factory script — /opt/data/config.yaml doesn't exist in WebUI container
- **#84**: Factory script customer key missing dashscope-vision, deepseek-chat, deepseek-v4-flash

### Architecture Decisions
1. **Legacy mode required**: DeepSeek-V4-Pro won't call generate_image tool in Native mode
2. **Separate "Custodian Images" model**: Silences confused text by making chat path fail
3. **One key per customer**: All models (chat, vision, images, video) under one budget pool
4. **Systemd cleanup timer**: 3 days for generated images, 30 days for uploaded files
5. **Upload limits**: RAG_FILE_MAX_SIZE=50, RAG_FILE_MAX_COUNT=10

## Machine Credentials (for future sessions)
- Dell: custodian@10.0.0.10 / Xmanuel@123@!
- VM205: custodian@192.168.50.205 / JsydvQ9rXFzZFrhp
- Connect via paramiko when SSH password prompt fails

## Related Files
- Implementation plan: features/image-generation-complete-plan.md
- Bug index: research/custodian-bug-index.md
- Factory script: scripts/setup-custodian-factory.sh
- Budget proxy script: scripts/setup-budget-proxy.sh
- Docker Compose: scripts/docker-compose.custodian-factory.yml
- GitHub: https://github.com/blackwealthinc/custodian-deploy
