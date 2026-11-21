#!/usr/bin/env bash
# Создаёт заготовку проекта в ~/Programming_Projects/<Lang>_Projects и открывает в Zed.
# Меню — ASCII в терминале. Вызывается из Zed по Ctrl+Shift+N.
set -u

ROOT="$HOME/Programming_Projects"

read -rp "Имя проекта: " name
name="$(printf '%s' "$name" | tr 'A-Z ' 'a-z_' | tr -cd 'a-z0-9_-')"
[[ -n "$name" ]] || { echo "Отменено"; sleep 1; exit 0; }

printf '  1) python\n  2) csharp\n  3) cpp\n'
read -rp "Язык [1-3]: " n
case "$n" in
    1|python) lang=python; sub=Python_Projects ;;
    2|csharp) lang=csharp; sub=CSharp_Projects ;;
    3|cpp)    lang=cpp;    sub=Cpp_Projects ;;
    *) echo "Отменено"; sleep 1; exit 0 ;;
esac

dir="$ROOT/$sub/$name"
if [[ -e "$dir" ]]; then
    echo "«$name» уже существует — открываю"
    zeditor -r "$dir" &
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
esac

echo "→ $dir"
zeditor -r "$dir" &
sleep 1
