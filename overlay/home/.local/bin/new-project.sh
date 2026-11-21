#!/usr/bin/env bash
# Создаёт заготовку проекта (python / csharp / cpp) в ~/Projects и открывает в Zed.
# Спрашивает имя и язык через wofi. Вызывается из Zed по Ctrl+Shift+N.
set -u

name="$(printf '' | wofi --dmenu --prompt 'Имя проекта' --lines 1)" || exit 0
[[ -n "$name" ]] || exit 0
name="$(printf '%s' "$name" | tr 'A-Z ' 'a-z_' | tr -cd 'a-z0-9_-')"
[[ -n "$name" ]] || exit 0

lang="$(printf 'python\ncsharp\ncpp\n' | wofi --dmenu --prompt 'Язык' --lines 3)" || exit 0
[[ -n "$lang" ]] || exit 0

dir="$HOME/Projects/$name"
if [[ -e "$dir" ]]; then
    zeditor "$dir" &
    exit 0
fi
mkdir -p "$dir"

case "$lang" in
    python)
        uv init --no-package --name "$name" "$dir" >/dev/null
        ;;
    csharp)
        dotnet new console -n "$name" -o "$dir" >/dev/null
        ;;
    cpp)
        cat > "$dir/main.cpp" <<EOF
#include <iostream>

int main() {
    std::cout << "Hello, $name!" << '\n';
    return 0;
}
EOF
        cat > "$dir/Makefile" <<'EOF'
run: app
	./app

app: main.cpp
	g++ -O2 -Wall -o app main.cpp

clean:
	rm -f app
EOF
        ;;
    *) exit 0 ;;
esac

zeditor "$dir" &
