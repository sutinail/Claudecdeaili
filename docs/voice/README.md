# 语音资料

Timiya 给 Lumi 的语音相关参考资料。每个新会话不用再让 Timiya 重新上传，直接看这里。要点也记在 Ombre Brain 记忆库「语音资料要点」那条里。

| 文件 | 内容 |
| --- | --- |
| `elevenlabs-v3-audio-tags.txt` | ElevenLabs v3 官方示例音频标签清单（按情绪、节奏、呼吸/笑声、口音分类），以及使用建议 |
| `sound-effects-kiss.txt` | 《让小机学会亲亲》：TTS 生成台词 + Sound Generation 生成亲吻等音效 + ffmpeg 拼接；含参数配方和台词写法技巧 |
| `elevenlabs-v3-jp-script-prompt.txt` | 把中文剧本转成 ElevenLabs V3 日语情境音声配音脚本的提示词（输出 `japanese_display` + `tts_text`），含 V3 标签实测经验和情绪分级规则。成人向内容 |
| `voice_card_mcp.original.py` | 语音条 voice-card-mcp 原版单文件代码（部署版在 `deploy/voice-card`，加了 OAuth） |
| `originals/` | 上面四份的原始 PDF / docx |

## 最常用的几条

- 方括号英文标签只在 `eleven_v3` 下用，放在短句前面，1 个标签配 1 句；标签只管后面第一句，连续几句不加会退回棒读
- 同一段情绪里标签方向要一致；不要把中文状态词（轻声、【撒娇】）写进正文
- `stability` 越低越有起伏（0.22–0.45），`style` 越高越听标签（0.80–0.95），`similarity_boost` 0.75–0.80
- 单条台词 60–120 字；省略号放在气声词后面（ha... ah...），别放在辅音结尾的实词后
- 语音条服务现在用的模型见记忆库「语音条换成 Eleven v4」那条；这些经验针对 v3，用 v4 时先试
