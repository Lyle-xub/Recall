# 本地与在线模型

## 默认：应用内下载，原生离线推理

点击首页 **Set up offline models**，或打开 **Settings → Models**。Provider 默认选择 **Built-in**。下载 Qwen3 问答模型与 Whisper 转写模型后，软件自动加载，无需终端命令或独立服务。已下载的模型重启后保留。

| 用途 | 模型与官方来源 | 下载量 | 引擎 |
|---|---|---|---|
| 问答 | [Qwen3-1.7B Q8 GGUF](https://huggingface.co/Qwen/Qwen3-1.7B-GGUF) | 1,834,426,016 字节 | [llama.cpp b11160](https://github.com/ggml-org/llama.cpp/releases/tag/b11160) |
| 转写 | [Whisper Base GGML](https://huggingface.co/ggerganov/whisper.cpp) | 147,951,465 字节 | [whisper.cpp v1.8.3](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.8.3) |

权重 URL 固定到仓库提交，并以 SHA-256 校验。清单见 `shared/models/catalog.json`。下载支持进度、暂停、恢复与重试，完成后才允许推理；中断的下载不会被当作完整模型。模型存放在应用数据目录的 `models` 文件夹。建议至少 8 GB 内存及约 3 GB 可用存储，历史录制另占空间。

问答引擎只监听随机的 `127.0.0.1` 端口，使用每次启动生成的随机令牌；没有浏览器界面，也不允许跨网络访问。语音直接调用打包的原生引擎。macOS 问答使用 Metal，Windows 包采用 CPU 后端。退出应用停止推理进程。

开启 **Transcribe recorded audio**，并按需要启用系统音频与麦克风录制。新录制分开保存两种音轨，分别标记 Meeting 和 You。默认每 5 分钟或暂停录制时转写；失败后可从历史详情重试。此实现区分音频来源，不做每个远端参会人的声纹身份识别。

## 高级选项：已有的聊天模型

Ollama 或 LM Studio 在独立进程中加载模型。原生应用通过回环地址连接，不限制模型家族。先在模型运行时中下载 / 加载模型，然后打开应用的 Models 设置，填写实际模型 ID，点击测试连接。

Ollama 的兼容接口说明：[官方兼容接口文档](https://ollama.com/blog/openai-compatibility)。服务地址填 `http://127.0.0.1:11434/v1`。示例默认名称 `qwen3:8b` 只是可编辑值，这是接入外部服务时的可编辑示例；默认 Built-in 模式由应用下载并管理自己的模型。

LM Studio 开启其本地服务器后，填 `http://127.0.0.1:1234/v1`，使用服务器当前列出的模型 ID。

## 高级选项：已有的本地语音服务

仓库附带一个可选、仅绑定本机的 Whisper 服务。它使用 [faster-whisper 的本地 CTranslate2 推理](https://github.com/SYSTRAN/faster-whisper)。可使用 Python 3.11 / 3.12 创建独立环境：

macOS：

```bash
python3.12 -m venv .speech-venv
source .speech-venv/bin/activate
pip install -r scripts/local-speech/requirements.txt
python scripts/local-speech/server.py --model base
```

Windows PowerShell：

```powershell
py -3.12 -m venv .speech-venv
.speech-venv\Scripts\python -m pip install -r scripts/local-speech/requirements.txt
.speech-venv\Scripts\python scripts/local-speech/server.py --model base
```

首次启动会下载所选模型。之后可添加 `--offline` 强制仅使用缓存，或将 `--model` 设置为已下载的模型目录。默认 CPU int8；有相应 NVIDIA 环境时可使用 `--device cuda`。模型推理没有外发音频的逻辑。

在应用中开启 **Transcribe recorded audio**，选择 **Local Whisper**，地址 `http://127.0.0.1:8080/v1`，模型 `whisper-1`，无需 API key。语音与系统音频录制开关须按需要开启。暂停录制或一个 5 分钟片段完成后生成转写；失败时保留原始录制，可在详情页 / 菜单中重试。

`whisper-1` 在这个本地服务中是已加载模型的兼容别名，并不调用在线服务。

## 在线模型

选择 **Online compatible**，填入服务商的 HTTPS base URL、模型名和密钥。聊天与语音使用独立配置，因为服务商不一定同时支持两种接口。

密钥在 macOS 保存到 Keychain，在 Windows 用当前用户 DPAPI 加密。设置 JSON 中不存明文密钥。默认不会联网生成或自动上传过去的数据；提问以及开启在线转写才触发对应请求。

## 诊断

- 内置模型未就绪：先在模型卡片下载，等待校验完成。
- 内置引擎缺失：重新解压完整应用包，不要单独移动 exe。
- 外部服务连接拒绝：启动对应服务并核对端口。
- HTTP 401 / 403：检查密钥与服务权限。
- HTTP 404：检查 base URL 是否为兼容 API 路径；不要重复填写 `/v1/v1`。
- 无可用模型：确认模型运行时已加载模型，也可手动输入服务支持的模型 ID。
- 语音无结果：检查录制是否确实包含音轨、麦克风 / 系统音频开关是否开启。
- 本地模型响应慢：选择更小或量化的模型。问答采用流式输出，可中途停止。
