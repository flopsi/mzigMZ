#!/bin/bash
# .claude/hooks/protect-sensitive.sh
# Prevent modification of sensitive files (.env, secrets, etc.)

read JSON
FILE=$(python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('file_path', ''))")

PROTECTED_PATTERNS=('\.env$' '\.env\.local$' '\.env\.production$' 'secrets\.yaml$' '\.ssh/')

for pattern in "${PROTECTED_PATTERNS[@]}"; do
    if echo "$FILE" | grep -qE "$pattern"; then
        echo "Error: Direct modification of sensitive file '$FILE' is not allowed." >&2
        exit 2
    fi
done

exit 0
