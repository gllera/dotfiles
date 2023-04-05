# dotfiles

To install execute:

```bash
mkdir -p "$HOME/.config"
echo '*' > "$HOME/.config/.gitignore"

git -C "$HOME/.config" init -q
git -C "$HOME/.config" remote add origin https://github.com/gllera/dotfiles.git
git -C "$HOME/.config" fetch origin master
git -C "$HOME/.config" checkout master

echo '[[ ! -f "$HOME/.config/zsh/zshrc" ]] || source "$HOME/.config/zsh/zshrc"' >> "$HOME/.zshrc"
```
