# TapNow 0.4.155 模型配置汇总

本机安装包的客户端模型目录包含 119 个标识：LLM 17、图像 31、视频 57、音频 14。图像与视频目录逐项匹配枚举；音频匹配语音、音乐、音效三组枚举。媒体模型共有 155 个声明变体。数据来自实际安装包的静态解析，没有执行模型生成。<a href="#source-1">[cite:1]</a>

模型的描述、时长和输入限制是 TapNow 客户端的声明，不是本轮独立测评分数。18 个条目声明默认隐藏，6 个条目由地区环境决定默认隐藏；服务端还能覆盖 visible / coming_soon / hidden，所以不能把静态状态当成当前账户实际可用性。<a href="#source-2">[cite:2]</a>

目录里的模型 ID 与 provider 是 TapNow 的路由标识。例如 Seedance 2.0 的 provider 为 tapnow，DeepSeek V4 Pro 的 provider 为 alibaba，GPT / Claude 分别经过 azure / aws。直接接入用户自己的 API 时，必须另行配置该服务接受的模型标识与协议。<a href="#source-1">[cite:1]</a>

完整的生成模式、参考数量范围、分辨率、时长选项、默认值和条件表达式位于同目录的 `TapNow模型目录.json`。表中展示主默认值；具有多个模式的模型以其首个声明变体为摘要，完整变体均保留。<a href="#source-1">[cite:1]</a>

## LLM（17）

| 模型 | 目录标识 | 服务路由 | 模式 | 默认参数摘要 | 客户端默认状态 |
|---|---|---|---|---|---|
| Gemini 3.5 Flash | gemini-3.5-flash | google | 文本、图像输入 | 未声明 | 展示 |
| Gemini 3.6 Flash | gemini-3.6-flash | google | 文本、图像输入 | 未声明 | 展示 |
| Gemini 3.1 Pro | gemini-3.1-pro | google | 文本、图像输入 | 未声明 | 展示 |
| Gemini 3.1 Flash Lite | gemini-3.1-flash-lite | google | 文本、图像输入 | 未声明 | 展示 |
| Gemini 3 Pro | gemini-3-pro | google | 文本、图像输入 | 未声明 | 隐藏 |
| Gemini 3 Flash | gemini-3-flash | google | 文本、图像输入 | 未声明 | 展示 |
| Gemini 2.5 Flash | gemini-2.5-flash | google | 文本、图像输入 | 未声明 | 隐藏 |
| Gemini 2.5 Pro | gemini-2.5-pro | google | 文本、图像输入 | 未声明 | 隐藏 |
| DeepSeek V4 Pro | deepseek-v4-pro | alibaba | 文本 | 未声明 | 展示 |
| Grok 4.6 | grok-4.6 | xai | 文本 | 未声明 | 地区条件 |
| GPT-5.6 Sol | gpt-5.6-sol | azure | 文本 | 未声明 | 展示 |
| GPT-5.6 Terra | gpt-5.6-terra | azure | 文本 | 未声明 | 展示 |
| GPT-5.6 Luna | gpt-5.6-luna | azure | 文本 | 未声明 | 展示 |
| GPT-6 Astra | gpt-6-astra | azure | 文本、图像输入 | 未声明 | 展示 |
| Claude Opus 5 | anthropic.claude-opus-5 | aws | 文本 | 未声明 | 展示 |
| Claude Fable 5 | anthropic.claude-fable-5 | aws | 文本 | 未声明 | 展示 |
| Claude Fable 5.1 | anthropic.claude-fable-5-1 | aws | 文本 | 未声明 | 展示 |

## AIGC 图像（31）

| 模型 | 目录标识 | 服务路由 | 模式 | 默认参数摘要 | 客户端默认状态 |
|---|---|---|---|---|---|
| GPT Image 2.5 Flare | gpt-image-2.5-flare | openai | 文生图、图生图 | {"aspectRatio":"1:1","imageSize":"1K","quality":"low"} | 展示 |
| GPT Image 2.5 Sunburst | gpt-image-2.5-sunburst | openai | 文生图、图生图 | {"aspectRatio":"1:1","imageSize":"1K","quality":"low"} | 展示 |
| GPT Image2 | gpt-image-2 | openai | 文生图、图生图 | {"aspectRatio":"1:1","imageSize":"1K","quality":"low"} | 展示 |
| Nano Banana 2.1 | nano-banana-2.1 | google | 文生图、图生图 | {"aspectRatio":"Auto","imageSize":"1K","enableGoogleSearch":false,"enable_image_search":false,"thinking_level":"HIGH"} | 展示 |
| Banana 2 | nano-banana-flash | google | 文生图、图生图 | {"aspectRatio":"Auto","imageSize":"1K","enableGoogleSearch":false,"enable_image_search":false,"thinking_level":"HIGH"} | 展示 |
| Nano Banana 2 Lite | nano-banana-flash-lite | google | 文生图、图生图 | {"aspectRatio":"Auto","imageSize":"1K","thinking_level":"HIGH"} | 展示 |
| Banana Pro | tamar-google-gemini-pro | google | 文生图、图生图 | {"aspectRatio":"Auto","imageSize":"2K","enableGoogleSearch":false} | 展示 |
| Banana | nano-banana | google | 文生图、图生图 | {"aspectRatio":"Auto"} | 展示 |
| HY Image 3.5 Preview | hunyuan-image-3.5-preview | tencent | 文生图、图生图 | {"aspectRatio":"1:1","imageSize":"2K"} | 展示 |
| Reve 2.1 | reve-2.1 | fal | 文生图 | {"aspectRatio":"Auto","outputFormat":"png"} | 展示 |
| Recraft V4 | fal-recraft-v4 | fal | 文生图 | {"aspectRatio":"1:1","generateMode":"std"} | 展示 |
| Recraft V4 矢量版 | fal-recraft-v4-vector | fal | 文生图 | {"aspectRatio":"1:1","generateMode":"std"} | 展示 |
| Seedream 5.0 Lite | doubao-seedream-5.0-lite | bytedance | 文生图、图生图 | {"aspectRatio":"1:1","imageSize":"2K"} | 展示 |
| Seedream 5.0 Pro | doubao-seedream-5.0-pro | bytedance | 文生图、图生图 | {"aspectRatio":"1:1","imageSize":"2K"} | 展示 |
| TapNow Flash | tapnow-image-turbo | tapnow | 文生图 | {"aspectRatio":"1:1","imageSize":"2K"} | 隐藏 |
| Grok2 Image | grok-2-image | xai | 文生图 | {"aspectRatio":"Auto"} | 地区条件 |
| Grok Imagine | grok-imagine-image | xai | 文生图、图生图 | {"aspectRatio":"Auto","imageSize":"1K"} | 地区条件 |
| Grok Imagine Quality | grok-imagine-image-quality | xai | 文生图、图生图 | {"aspectRatio":"Auto","imageSize":"2K"} | 地区条件 |
| Seedream 4.0 | doubao-seedream-4.0 | bytedance | 文生图、图生图 | {"aspectRatio":"Auto(4K)","sequential_image_generation":"auto"} | 展示 |
| Seedream 4.5 | doubao-seedream-4.5 | bytedance | 文生图、图生图 | {"aspectRatio":"16:9","imageSize":"2K","sequential_image_generation":"auto"} | 展示 |
| MJ V7 | midjourney-v7 | midjourney | 文生图、图生图 | {"aspectRatio":"16:9"} | 展示 |
| MJ V8.2 | midjourney-v8.2 | midjourney | 文生图、图生图 | {"aspectRatio":"16:9"} | 展示 |
| MJ V8.1 | midjourney-v8.1 | midjourney | 文生图、图生图 | {"aspectRatio":"16:9"} | 展示 |
| MJ Niji7 | midjourney-niji7 | midjourney | 文生图、图生图 | {"aspectRatio":"16:9"} | 展示 |
| GPT Image | gpt-image-1 | openai | 文生图、图生图 | {"aspectRatio":"1:1"} | 隐藏 |
| IMAGEN 4.0 | imagen-4.0 | google | 文生图 | {"aspectRatio":"1:1"} | 隐藏 |
| Flux 2 Pro | flux-2-pro | bfl | 文生图、图生图 | {"aspectRatio":"16:9","imageSize":"1K"} | 隐藏 |
| Flux Max | flux-kontext-max | bfl | 文生图、图生图 | {"aspectRatio":"16:9"} | 展示 |
| Flux | flux-kontext-pro | bfl | 文生图、图生图 | {"aspectRatio":"16:9"} | 展示 |
| 世界编辑 | world-edit | tamar | 图生图 | {"aspectRatio":"Auto","imageSize":"2K"} | 隐藏 |
| Banana Pro | nano-banana-2 | google | 文生图、图生图 | {"aspectRatio":"Auto","imageSize":"2K","enableGoogleSearch":false} | 隐藏 |

## 视频（57）

| 模型 | 目录标识 | 服务路由 | 模式 | 默认参数摘要 | 客户端默认状态 |
|---|---|---|---|---|---|
| Seedance 2.0 | seedance-2.0 | tapnow | 参考生成、文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","duration":5,"resolution":"720p","generateAudio":true} | 展示 |
| Seedance 2.0 Mini | seedance-2.0-mini | tapnow | 参考生成、文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","duration":5,"resolution":"480p","generateAudio":true} | 展示 |
| Seedance 2.0 Fast | seedance-2.0-fast | tapnow | 参考生成、文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","duration":5,"resolution":"720p","generateAudio":true} | 展示 |
| Seedance 2.5 | seedance-2.5 | tapnow | 参考生成、视频编辑、文生视频、图生视频、首尾帧 | {"aspectRatio":"adaptive","duration":5,"resolution":"720p","generateAudio":true} | 展示 |
| Seedance 2.5 4K | seedance-2.5-4k | tapnow | 参考生成、视频编辑、文生视频、图生视频、首尾帧 | {"aspectRatio":"adaptive","duration":5,"resolution":"4k","generateAudio":true} | 展示 |
| Seedance 2.5 样片 | seedance-2.5-draft | tapnow | 参考生成、视频编辑、文生视频、图生视频、首尾帧 | {"aspectRatio":"adaptive","duration":5,"resolution":"480p","generateAudio":true} | 展示 |
| MiniMax H3 | MiniMax-H3 | minimax | 文生视频、图生视频、首尾帧、参考生成 | {"duration":5,"resolution":"2K","aspectRatio":"16:9"} | 展示 |
| MiniMax H3 Max | MiniMax-H3-Max | minimax | 文生视频、图生视频 | {"duration":5,"resolution":"768P","aspectRatio":"16:9"} | 展示 |
| Wan 3.0 | wan3.0-video | wanxiang | 文生视频、图生视频、参考生成、视频参考 | {"aspectRatio":"adaptive","resolution":"1080P","duration":5,"generateAudio":true,"turbo":false} | 展示 |
| Kling 3.0 Omni | kling-video-o3 | kling | 文生视频、图生视频、首尾帧、参考生成、视频参考 | {"aspectRatio":"16:9","duration":8,"generateAudio":true,"generateMode":"pro"} | 展示 |
| Kling 4.0 | kling-4.0-preview | kling | 文生视频、图生视频、首尾帧、参考生成、视频编辑 | {"duration":10,"resolution":"1080p","times":1,"aspectRatio":"16:9"} | 展示 |
| FLUX 3 | flux-3 | bfl | 文生视频、图生视频 | {"aspectRatio":"16:9","resolution":"720p","duration":5,"generateAudio":true} | 展示 |
| Depth Anything Video | depth-anything-video | fal | 视频编辑 | 未声明 | 展示 |
| Gemini Omni Flash | gemini-omni-flash | google | 文生视频、图生视频、视频编辑、参考生成 | {"aspectRatio":"16:9","duration":10} | 展示 |
| Gemini Omni 1.1 Flash | gemini-omni-1.1-flash | google | 文生视频、图生视频、视频编辑、参考生成 | {"aspectRatio":"16:9","duration":10} | 展示 |
| Kling 3.0 | kling-v3-pro | kling | 文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","duration":8,"generateAudio":true,"generateMode":"pro"} | 展示 |
| HappyHorse 1.0 | happyhorse-1.0 | alibaba | 文生视频、图生视频、参考生成 | {"aspectRatio":"16:9","resolution":"1080P","duration":5} | 展示 |
| HappyHorse 1.1 | happyhorse-1.1 | alibaba | 文生视频、图生视频、参考生成 | {"aspectRatio":"16:9","resolution":"1080P","duration":5} | 展示 |
| HappyHorse 1.0 视频编辑 | happyhorse-1.0-edit | alibaba | 视频编辑 | {"resolution":"1080P"} | 展示 |
| Kling 3.0 Omni 视频编辑 | kling-o3-video-edit | kling | 视频编辑 | {"duration":5,"keepOriginalAudio":false} | 隐藏 |
| Kling 3.0 Omni 视频编辑 | kling-video-o3-edit | kling | 视频编辑 | {"generateMode":"pro"} | 展示 |
| Kling O1 视频编辑 | kling-video-o1-edit | kling | 视频编辑 | {"keepOriginalSound":"yes","duration":5} | 展示 |
| Kling O1 | kling-video-o1 | kling | 文生视频、图生视频、首尾帧、参考生成、视频参考 | {"aspectRatio":"16:9","duration":5} | 展示 |
| VEO3.1-Lite | veo3.1-lite | google | 文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","duration":8,"resolution":"720p","generateAudio":true} | 展示 |
| VEO3.1-Lite 视频延长 | veo3.1-lite-extend | google | 视频延长 | {"aspectRatio":"16:9","duration":8,"resolution":"720p"} | 隐藏 |
| VEO3.1-Fast | veo3.1-fast | google | 文生视频、图生视频、首尾帧、参考生成 | {"aspectRatio":"16:9","duration":8,"resolution":"1080p","generateAudio":true} | 展示 |
| VEO3.1 | veo3.1 | google | 文生视频、图生视频、首尾帧、参考生成 | {"aspectRatio":"16:9","duration":8,"resolution":"1080p","generateAudio":true} | 展示 |
| Seedance 1.5 Pro | seedance-1.5-pro | byteplus | 文生视频、图生视频 | {"aspectRatio":"16:9","duration":5,"resolution":"720p","generateAudio":true} | 隐藏 |
| Wan 2.6 | wanxiang-v2-6 | wanxiang | 文生视频、图生视频、视频参考、参考生成 | {"aspectRatio":"16:9","resolution":"720P","duration":5,"generateAudio":true,"generateMultiClip":false} | 展示 |
| Kling 2.6 | kling-v2-6 | kling | 文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","duration":5,"generateAudio":true} | 展示 |
| Hailuo-2.3 | MiniMax-Hailuo-2.3 | minimax | 文生视频、图生视频 | {"duration":6,"resolution":"1080P"} | 展示 |
| Seedance 1.0 Pro | doubao-seedance-pro | bytedance | 文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","duration":5,"resolution":"1080p"} | 展示 |
| Seedance 1.0 Lite | doubao-seedance-lite | bytedance | 文生视频、图生视频、首尾帧、参考生成 | {"aspectRatio":"16:9","duration":5,"resolution":"1080p"} | 隐藏 |
| MJ Video | midjourney-video | midjourney | 图生视频、首尾帧 | {"resolution":"720P","loop":false} | 展示 |
| Hailuo-02 | minimax | minimax | 文生视频、图生视频、首尾帧 | {"duration":6,"resolution":"768P"} | 展示 |
| Hailuo-2.3 Fast | MiniMax-Hailuo-2.3-Fast | minimax | 图生视频 | {"duration":6,"resolution":"1080P"} | 展示 |
| Vidu-Q1 | viduq1 | vidu | 图生视频、首尾帧、参考生成 | 未声明 | 隐藏 |
| Vidu Q2 | viduq2 | vidu | 文生视频、参考生成 | {"duration":5,"resolution":"540p","aspectRatio":"16:9"} | 展示 |
| Vidu Q2 Pro | viduq2-pro | vidu | 图生视频、首尾帧 | {"resolution":"1080p","duration":5} | 展示 |
| Vidu Q2 Turbo | viduq2-turbo | vidu | 图生视频、首尾帧 | {"resolution":"1080p","duration":5} | 展示 |
| Vidu Q3 | viduq3-pro | vidu | 文生视频、图生视频 | {"duration":5,"resolution":"720p","aspectRatio":"16:9","generateAudio":true,"style":"general"} | 展示 |
| Kling 2.1 | kling | kling | 文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","duration":5} | 展示 |
| Kling 2.5 | kling-v2-5-turbo-pro | kling | 文生视频、图生视频 | {"aspectRatio":"16:9","duration":5} | 展示 |
| Kling 2.6 动作迁移 | kling-motion-control | kling | 视频编辑 | {"character_orientation":"image","generateMode":"pro","keep_original_sound":"yes","times":1} | 展示 |
| Wan 2.2 | wanxiang-plus | wanxiang | 文生视频、图生视频 | {"resolution":"1080P","duration":5} | 展示 |
| Wan 2.2 Flash | wanxiang-i2v-flash | wanxiang | 图生视频 | {"resolution":"480P","duration":5} | 展示 |
| Wan 2.5 | wanxiang-preview | wanxiang | 文生视频、图生视频 | {"aspectRatio":"16:9","resolution":"1080P","duration":5,"generateAudio":true} | 展示 |
| PixVerse 5.5 | pixverse-v5.5 | pixverse | 文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","resolution":"1080P","duration":5,"generateAudio":true,"generateMultiClip":false} | 展示 |
| PixVerse 5.0 | pixverse-v5 | pixverse | 文生视频、图生视频、首尾帧 | {"aspectRatio":"16:9","resolution":"1080P","duration":5,"soundEffect":false} | 展示 |
| VEO3 | veo3 | google | 文生视频、图生视频 | {"aspectRatio":"16:9","duration":8,"resolution":"1080p","generateAudio":true} | 隐藏 |
| VEO3-Fast | veo3-fast | google | 文生视频、图生视频 | {"aspectRatio":"16:9","duration":8,"resolution":"1080p","generateAudio":true} | 隐藏 |
| VEO2 | veo2 | google | 首尾帧 | {"aspectRatio":"16:9"} | 隐藏 |
| Sora 2 | sora-2-standard | fal | 文生视频、图生视频 | {"aspectRatio":"16:9","resolution":"720p","duration":8} | 展示 |
| Sora 2 Pro | sora-2-pro | fal | 文生视频、图生视频 | {"aspectRatio":"16:9","resolution":"1080p","duration":8} | 展示 |
| Grok Imagine 1.5 | grok-imagine-video-1.5 | xai | 图生视频 | {"resolution":"720p","duration":5} | 地区条件 |
| Grok Imagine | grok-imagine-video | xai | 文生视频、图生视频、参考生成、视频编辑 | {"aspectRatio":"16:9","resolution":"720p","duration":5} | 地区条件 |
| OmniHuman 1.5 | omnihuman-1.5 | byteplus | 数字人 | 未声明 | 展示 |

## 音频（14）

| 模型 | 目录标识 | 服务路由 | 模式 | 默认参数摘要 | 客户端默认状态 |
|---|---|---|---|---|---|
| ElevenLabs Music v1 | music_v1 | elevenlabs | 音乐 | {"force_instrumental":false,"lyric_mode":false,"lyrics":""} | 展示 |
| ElevenLabs Sound Effect | eleven_sound_effect | elevenlabs | 音效 | {"loop":false,"prompt_influence":0.3} | 展示 |
| ElevenLabs Multilingual v2 | eleven_multilingual_v2 | elevenlabs | 语音 | {"speed":1,"stability":0.5,"similarity_boost":0.5,"style":0} | 隐藏 |
| ElevenLabs v3 | eleven_v3 | elevenlabs | 语音 | {"stability":0.5} | 展示 |
| Fish Audio Drama 3 | drama-3 | fish-audio | 语音 | {"voice_id":"c70cfb98867a4bfb9ae20d2401257b92","format":"mp3"} | 展示 |
| Lyria 3 Clip | lyria-3-clip-preview | google | 音乐 | 未声明 | 展示 |
| Lyria 3 Pro | lyria-3-pro-preview | google | 音乐 | 未声明 | 展示 |
| MiniMax Music 2.6 | music-2.6 | minimax | 音乐 | {"force_instrumental":false,"lyric_mode":false,"lyrics":""} | 展示 |
| Mureka 7.6 | mureka-7.6 | mureka | 音乐 | {"lyric_mode":false,"lyrics":""} | 展示 |
| Mureka O2 | mureka-o2 | mureka | 音乐 | {"lyric_mode":false,"lyrics":""} | 展示 |
| Mureka 8 | mureka-8 | mureka | 音乐 | {"lyric_mode":false,"lyrics":""} | 展示 |
| Seed Audio 1.0 | doubao-seed-audio-1-0 | doubao | 语音 | {"format":"wav","sample_rate":24000,"speech_rate":0,"pitch_rate":0,"loudness_rate":0,"enable_subtitle":false} | 展示 |
| Sonilo Music | sonilo-music | sonilo | 音乐 | {"duration":60} | 展示 |
| Sonilo SFX | sonilo-sfx | sonilo | 音效 | {"duration":10} | 展示 |

## 调用与配置边界

TapNow 的序列化器分别处理 57 个视频标识、31 个图像标识、14 个音频标识，再调用自己的 conversation generation 服务。这些客户端路径不能作为厂商公开 API 的默认地址；外部服务必须按实际协议接入。<a href="#source-1">[cite:1]</a>

CC Switch 的可复用机制是共享服务连接、集中模型映射、按用途切换目标，以及与已开始请求分离的配置更新。它的官方文档还提供 OpenAI 兼容的模型发现机制。ClipSlots 可将相同管理方式应用到 Agent、出题、画布文本、图像、视频、语音、音乐和音效。<a href="#source-3">[cite:3]</a><a href="#source-4">[cite:4]</a>

服务端实际模型目录和调用权限没有在本轮静态分析中验证。模型目录应完整展示，接入操作再绑定用户服务及实际 model ID；配置不全或输入不受支持时应明确提示，并保留原节点内容。

## 来源

<a id="source-1"></a>[cite:1] 本机 TapNow 0.4.155：`vendor-pkg-tap-models-CWO_NP4e.js`、`vendor-shared-C-U24Utf.js`、`vendor-pkg-endpoints-BZ5e7w2O.js`；路径与 SHA-256 见 `来源与覆盖校验.json`。REA Evidence `ev_46cbe389039418c1b9ce4f6ec6a9abeb69685549f44fd040f3bdbed4aca2cc17`。REA 语义图有资源限制，声明表与请求映射另以受限 AST 解析器逐项核验。

<a id="source-2"></a>[cite:2] 同一安装包 `vendor-pkg-core-E7gSgLFq.js` 的地区判断，以及模型模块的 `G1` / `Ot` visibility override 逻辑。静态语法证据，不代表服务端当前配置。

<a id="source-3"></a>[cite:3] CC Switch 官方文档：[Add Provider](https://ccswitch.io/en/docs?item=add&section=providers)。

<a id="source-4"></a>[cite:4] CC Switch 官方文档：[Switch Provider](https://ccswitch.io/en/docs?item=switch&section=providers)。
