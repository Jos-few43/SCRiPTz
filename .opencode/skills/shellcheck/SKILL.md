---
name: shellcheck
description: "Run shellcheck on all bash scripts. Triggers: 'check scripts', 'lint scripts', 'shellcheck', 'validate bash'."
---

# ShellCheck — SCRiPTz

## PHASE 1: FIND SCRIPTS
```bash
cd ~/SCRiPTz && find . -name "*.sh" -type f | sort
```

## PHASE 2: RUN SHELLCHECK
```bash
cd ~/SCRiPTz
for f in *.sh; do
  [ -f "$f" ] && shellcheck "$f" 2>&1 | head -20 && echo "---"
done
```
Note: shellcheck must be available (install via `distrobox enter fedora-tools -- sudo dnf install -y ShellCheck`).

## PHASE 3: REPORT
- Scripts checked: N
- Clean: N
- Warnings: N (list top issues)
- Errors: N (list all)
