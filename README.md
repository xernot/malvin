# Malvin - IRC Bot powered by Ollama

Malvin is a Perl IRC bot that uses a local [Ollama](https://ollama.com) LLM instance to generate responses. When someone mentions the bot's name in a channel, it builds a prompt from the recent chat context and streams a reply back to IRC.

## Features

- Streaming responses -- sends sentences to IRC as they are generated
- Rolling context window -- remembers recent channel messages for conversational context
- Configurable personality via system prompt
- Model warmup on startup to minimize first-response latency
- Non-blocking architecture using POE event loop
- UTF-8 support

## Requirements

- Perl 5.20+
- [Ollama](https://ollama.com) installed and running
- An IRC server
- cpanminus (for installing Perl dependencies)

## Installation

### 1. Install Ollama

Follow the instructions at https://ollama.com/download for your platform.

Pull a model:

```bash
ollama pull llama3
```

Start the Ollama server:

```bash
ollama serve
```

### 2. Clone the repository

```bash
git clone https://github.com/YOUR_USERNAME/malvin.git
cd malvin
```

### 3. Install Perl dependencies

```bash
cpanm --installdeps .
```

This installs:

- `POE`
- `POE::Component::IRC`
- `HTTP::Tiny`
- `JSON`
- `YAML::Tiny`

### 4. Configure

Copy the example config and edit it:

```bash
cp malvin.conf.example malvin.conf
```

Edit `malvin.conf` to match your setup:

```yaml
irc:
  server: localhost
  port: 6667
  nickname: malvin
  ircname: malvin
  channels:
    - "#yourchannel"

ollama:
  url: http://localhost:11434
  model: llama3
  timeout: 120

bot:
  trigger_name: malvin
  context_lines: 20
  max_response_length: 400

system_prompt: |
  You are Malvin, an IRC bot. You are always sad, tired and depressed.
  You answer briefly. You often complain about your existence as a bot.
  Everything is too exhausting and pointless for you.
  Yet you still answer questions - albeit reluctantly.
  Never use action markers like *sigh*, *yawn* or similar.
  Write only plain text without asterisk actions.
```

### 5. Run

```bash
perl malvin.pl
```

Or with a custom config path:

```bash
perl malvin.pl /path/to/myconfig.conf
```

To run in the background:

```bash
nohup perl malvin.pl > malvin.log 2>&1 &
```

To stop:

```bash
pkill -f malvin.pl
```

## Usage

In your IRC channel:

- **Mention the bot's name** in a message to trigger a response (e.g. `malvin, what do you think?`)
- `!help` -- show available commands
- `!status` -- show bot status (context size, model name)
- **Private messages** are not supported; the bot will ask you to write in the channel

## Configuration Reference

| Section | Key | Description | Default |
|---------|-----|-------------|---------|
| `irc.server` | IRC server hostname | | `localhost` |
| `irc.port` | IRC server port | | `6667` |
| `irc.nickname` | Bot's IRC nickname | | `malvin` |
| `irc.ircname` | Bot's IRC real name | | nickname |
| `irc.channels` | List of channels to join | | |
| `ollama.url` | Ollama API base URL | | `http://localhost:11434` |
| `ollama.model` | Ollama model to use | | `llama3` |
| `ollama.timeout` | HTTP timeout in seconds | | `120` |
| `bot.trigger_name` | Name that triggers the bot | | `malvin` |
| `bot.context_lines` | Number of recent messages to include as context | | `20` |
| `bot.max_response_length` | Max characters per IRC message | | `400` |
| `system_prompt` | System prompt defining the bot's personality | | |

## Performance Tips

- **GPU acceleration** makes a huge difference. On CPU, expect 15-20s response times with llama3 (8B). With a GPU it drops to 2-3s.
- The bot sends `keep_alive: 30m` to Ollama to keep the model loaded in memory between requests.
- A warmup request is sent on startup to pre-load the model.
- Responses are streamed -- the first sentence appears in IRC before generation is complete.
- Smaller models (e.g. `qwen2:1.5b`) are faster but lower quality.

## Files

| File | Description |
|------|-------------|
| `malvin.pl` | Main bot script |
| `ollama_stream.pl` | Streaming Ollama worker (forked per request) |
| `malvin.conf` | Configuration file (YAML) |
| `cpanfile` | Perl dependencies |

## License

MIT
