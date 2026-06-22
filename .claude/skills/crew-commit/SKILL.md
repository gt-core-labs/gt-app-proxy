---
name: crew-commit
description: >
  Canonical commit and push workflow for gt workers: conventional commits,
  worktree discipline, ff-only push to main, and merge-ready signal for
  autonomous polecats/dogs. Use when ready to commit and submit work.
version: "2.0.0"
author: "gt"
---

# Crew Commit — Canonical Git Workflow

Dos contextos de uso: **polecat/dog autónomo** (trabaja en worktree asignado,
señala via merge-ready channel) y **sesión interactiva** (mismo worktree pattern,
push ff:main directo).

> **⚠️ NUNCA** `git checkout -b` ni `git checkout` en el root compartido
> `/home/nixos/gt-core`. Cada actor trabaja en su propio worktree. El HEAD del
> root compartido es global — cambiarlo rompe el trabajo de otros agentes.

---

## Contexto A — Polecat / Dog autónomo

Tu worktree y rama ya existen (`<WorkDir>`, `$GT_BRANCH`). Solo commitear y
señalar completitud.

### Paso 1: Pre-flight

```bash
cd <WorkDir>          # siempre trabajar en tu worktree
git status            # verificar estado
git diff              # revisar cambios
```

### Paso 2: Stage

Preferir archivos específicos sobre `git add .`:

```bash
git add src/archivo.rs tests/archivo_test.rs
# nunca: git add -A (puede incluir secretos o binarios grandes)
```

Verificar antes de stage:
- [ ] Sin archivos `.env`, claves de API ni credenciales
- [ ] Sin prints de debug ni código temporal
- [ ] Sin cambios no relacionados mezclados

### Paso 3: Commit convencional

```bash
git commit -m "$(cat <<'EOF'
<type>(<scope>): <descripción imperativa, lowercase, sin punto, max 72 chars>

<body opcional: explica el POR QUÉ, no el qué>
EOF
)"
```

**Tipos:** `feat` | `fix` | `refactor` | `perf` | `test` | `docs` | `chore` | `ci`

**Ejemplos válidos:**
```
feat(gt-skills): add group field to skill registration
fix(gt-mcp): handle missing GT_TOKEN env gracefully
refactor(gt-issues): extract bead state machine to separate module
```

### Paso 4: Señalar completitud (merge_submit)

No pushear a main directamente. Llamar la herramienta MCP para que el **refinery** haga el merge:

```
mcp__gt__merge_submit  {"bead": "$GT_HOOK_BEAD", "branch": "$GT_BRANCH"}
```

(Fallback Bash si el MCP no está disponible):

```bash
d="$GT_CHANNEL_ROOT/merge-ready"; mkdir -p "$d"
i=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
printf '{"bead":"%s","branch":"%s"}' "$GT_HOOK_BEAD" "$GT_BRANCH" \
  > "$d/.$i.tmp" && mv "$d/.$i.tmp" "$d/$i.event"
```

Luego parar. El refinery hace el ff-merge a main.

### Paso 5: Escalar un bloqueo o incidente

Si algo salió mal y un humano debe actuar, abrir un bead de escalación en el tracker:

```bash
# Via MCP (desde el agente)
mcp__gt__issues.create.execute  title="[ESCALATION] <descripción>"  body="<contexto + bead afectado>"
```

O agregar un comentario al bead actual con el blocker. El **witness** detecta polecats
stuck y escala automáticamente; para bloqueadores explícitos, el bead de escalación
es el canal correcto.

---

## Contexto B — Sesión interactiva (mayor, overseer, worktree manual)

### Paso 1: Crear worktree por bead/feature

**Nunca** `git checkout -b` en el root compartido. Crear un worktree propio:

```bash
git worktree add /home/nixos/gt-core-wt-<bead-id>-iv -b <bead-id> main
cd /home/nixos/gt-core-wt-<bead-id>-iv
```

`iv` = tag de sesión interactiva. Nunca escribir en un `gt-core-wt-*` que no creaste.

### Paso 2: Stage y commit

Igual que Contexto A, Pasos 2 y 3.

### Paso 3: Rebase + push ff

```bash
git fetch origin
git rebase origin/main          # poner el bead encima del main remoto
git push origin <bead-id>:main  # fast-forward puro; falla si divergió → volver al rebase
```

### Paso 4: Limpiar worktree

```bash
cd /home/nixos/gt-core
git worktree remove /home/nixos/gt-core-wt-<bead-id>-iv
git branch -d <bead-id>
```

---

## Anti-patterns

| ❌ No hacer | ✅ En cambio |
|------------|-------------|
| `git checkout -b` en el root compartido | `git worktree add` con ruta por-actor |
| `git push origin main` directo | Push ff via `<branch>:main` o merge-ready channel |
| `git add .` o `git add -A` sin revisar | Stagear archivos específicos |
| `git merge --no-ff` | Rebase + ff push; nunca merge commits en main |
| Force-push sin entender el motivo | Resolver el root cause |
| Commitear `.env` o credenciales | Verificar `git diff` antes de stagear |

---

## Si hay conflictos en el rebase

```bash
# Resolver conflicto en el archivo marcado
git add <archivo-resuelto>
git rebase --continue
# Si no hay salida: revisar con `git status`
```

Si el conflicto es complejo: cherry-pick solo los commits únicos a una rama fresca
off main. Nunca forzar un merge de rama atrasada.

