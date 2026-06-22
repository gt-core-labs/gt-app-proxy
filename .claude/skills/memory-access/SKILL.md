# Memory access

Este rol puede consultar y guardar memoria de equipo via el namespace MCP `memory`.

- **Recuperar por significado:** `mcp__gt__memory_recall` (devuelve siempre las reglas `feedback` + top-k semantico).
- **Guardar una leccion:** `mcp__gt__memory_save` (upsert por `name`; kind feedback|project|reference|user).

NO escribas memorias en archivos `.md` locales — estan bloqueados; usa `memory.save`.
