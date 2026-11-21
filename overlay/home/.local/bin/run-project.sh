#!/usr/bin/env bash
# Запускает проект текущей директории: определяет язык по файлам-маркерам,
# иначе — по расширению переданного файла ($1). Вызывается из Zed по F5.
set -u
shopt -s nullglob
file="${1:-}"

if compgen -G '*.sln' >/dev/null || compgen -G '*.csproj' >/dev/null; then
    exec dotnet run

elif [[ -f main.py ]]; then
    exec uv run main.py

elif [[ -f Makefile ]]; then
    if grep -q '^run:' Makefile; then exec make run; else exec make; fi

else
    cpps=(*.cpp *.cc)
    if (( ${#cpps[@]} )); then
        g++ -O2 -Wall "${cpps[@]}" -o app && exec ./app
    fi
    case "$file" in
        *.py)        exec uv run "$file" ;;
        *.cs)        exec dotnet run ;;
        *.cpp|*.cc)  g++ -O2 -Wall "$file" -o app && exec ./app ;;
        *) echo "Не знаю, как запустить этот проект"; sleep 4 ;;
    esac
fi
