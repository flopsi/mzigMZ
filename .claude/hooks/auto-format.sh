#!/bin/bash
# .claude/hooks/auto-format.sh
# Auto-format code after file writes
# Supports: Python (ruff, black), JavaScript/TypeScript (prettier),
#           Rust (cargo fmt), Go (gofmt)

read JSON
FILE=$(python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('file_path', ''))")

if [[ -z "$FILE" ]]; then
    exit 0
fi

format_file() {
    local file="$1"
    case "$file" in
        *.py)
            if command -v ruff &> /dev/null; then
                ruff format "$file" 2>/dev/null
            elif command -v black &> /dev/null; then
                black "$file" 2>/dev/null
            fi
            ;;
        *.js|*.ts|*.jsx|*.tsx|*.json|*.md)
            if command -v prettier &> /dev/null; then
                prettier --write "$file" 2>/dev/null
            fi
            ;;
        *.rs)
            if command -v cargo &> /dev/null; then
                cargo fmt -- "$file" 2>/dev/null
            fi
            ;;
        *.go)
            if command -v gofmt &> /dev/null; then
                gofmt -w "$file" 2>/dev/null
            fi
            ;;
    esac
}

format_file "$FILE"
exit 0
