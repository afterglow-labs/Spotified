# Installing the Afterglow Spotified fork

For development in this checkout (Python 3.11 is the locally verified baseline):

```sh
uv venv --python 3.11
uv pip install -e '.[dev]'
.venv/bin/spotified --doctor -c profiles/corey.json
```

Without uv, use `python3.11 -m venv .venv` followed by `.venv/bin/python -m pip install -e '.[dev]'`.

The install commands below point to this fork. After installing, run `spotified --doctor` to check FFmpeg and configuration. Run `spotified --update-config` to create or refresh your default config without logging in. See the README for the personal preset.

> **Windows**

This guide uses *Scoop* (https://scoop.sh) to simplify installing prerequisites and *pipx* to manage Spotified itself.
There are other ways to install and run Spotified on Windows but this is the official recommendation, other methods of installation will not receive support.

- Open PowerShell (cmd will not work)
- Install Scoop by running:
  - `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`
  - `irm get.scoop.sh | iex`
- After installing scoop run: `scoop install python ffmpeg-shared git`
- Install pipx:
  - `python3 -m pip install --user pipx`
  - `python3 -m pipx ensurepath`
Now close PowerShell and reopen it to ensure the pipx command is available.
- Install Spotified with: `pipx install git+https://github.com/afterglow-labs/Spotified.git`
- Done! Use `spotified --help` for a basic list of commands or check the *README.md* file in Spotified's code repository for full documentation.

> **macOS**

- Open the Terminal app
- Install *Homebrew* (https://brew.sh) by running: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- After installing Homebrew run: `brew install python@3.11 pipx ffmpeg git`
- Setup pipx: `pipx ensurepath`
- Install Spotified: `pipx install git+https://github.com/afterglow-labs/Spotified.git`
- Done! Use `spotified --help` for a basic list of commands or check the README.md file in Spotified's code repository for full documentation.

> **Linux (Most Popular Distributions)**

- Install `python3`, `pip` (if a separate package), `ffmpeg`, and `git` from your distribution's package manager or software center.
- Then install pipx, either from your package manager or through pip with: `python3 -m pip install --user pipx`
- Install Spotified `pipx install git+https://github.com/afterglow-labs/Spotified.git`
- Done! Use `spotified --help` for a basic list of commands or check the README.md file in Spotified's code repository for full documentation.
