# 🧩 Dotfiles

Configuration files and setup scripts for a **minimal i3wm environment** running on **Ubuntu Server 24.04**.

---

## 🚀 Overview

This repository provides:
- A lightweight, keyboard-driven **i3 window manager** setup.
- Opinionated defaults for **performance, aesthetics, and usability**.
- Automated installation scripts for both **packages** and **personal configurations**.

---

## 🧠 Requirements

- Ubuntu Server 24.04 (minimal installation)
- `curl` and `sudo` installed

---

## ⚙️ Installation

Run the following commands to install all required packages and configurations:

```bash
# Core packages (i3wm, NVIDIA drivers, Google Chrome, cursor theme, etc.)
curl -LOsSf https://dub.sh/gllera-i3 && sudo sh gllera-i3

# Personal configurations
curl -LOsSf https://dub.sh/gllera-config && sh gllera-config
