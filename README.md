# gpt-cli
A simple command-line client to query the OpenAI GPT chat API.

# Instructions

- Place the script from `main/scripts/gpt-cli.sh` into your path.
- Requires: bash, curl, jq, stdbuf, awk, sed, and other common tools
- Ensure `gpt-cli.sh` is executable.
- Feel free to rename it to something shorter or add an alias.
- It will ask you for your OpenAI API Key the first time and save it in the settings file.
- By default it uses `$HOME/.chat/*`, which should be created with permissions 700.
- To see your settings run `gpt-cli.sh --settings`
- The script will intialize your `$HOME/.chat` directory the first time you use it.
- Copy over (or create) additional files from `instructions/*` into `$HOME/.chat/instructions`
- The default chat ID will be 'default', use `-id mychatid` to change it.
- Recommend to keep chat IDs short (each chat is a directory under `$HOME/.chat/chats`).
- There isn't much error checking/user hand-holding.

# Requirements

- Requires \*nix commands like: bash, curl, jq, stdbuf, awk, sed, mkdir, ...
- If you don't have `stdbuf` you can provide a replacement using the `CHAT_STDBUF` environment variable (it will have to parse the arguments), but you may not get the full streaming effect

# Usage

- Run `gpt-cli.sh -h` for usage help
- `chat --instr assistant -id mathchat -c "what is 1+1?" -id geekchat -c "what is a disturginator?" --instr author -id bookchat what book should I write next?`
