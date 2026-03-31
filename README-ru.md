# looper

Верификация при развёртывании для commands, skills и plugins Claude Code — выполняет тесты
установки, точности триггеров и поведенческий набор оценок (T5) в чистом Docker CC-контейнере.
Используется как этап 5 конвейера skill-test.

## Установка

```bash
bash install.sh
# или указать пользовательский каталог конфигурации Claude
bash install.sh --target ~/.claude
# или использовать соглашение CLAUDE_DIR
CLAUDE_DIR=~/.claude bash install.sh
```

Устанавливает:
- `commands/looper.md → ~/.claude/commands/looper.md`
- `assets/config/.claude.json → ~/.claude/looper/.claude.json`

> ✅ **Проверено**: покрыто конвейером skill-test (looper Stage 5).

## Использование

```
/looper --plugin <pkg>                    # установить и проверить packer/<pkg>/
/looper --plugin <pkg> --image <image>   # использовать явно указанный образ контейнера
```

## Требования

- **Docker** (должен быть доступен на хосте; при запуске в devcontainer looper обнаруживает это и завершается с подсказкой)
- **CC runtime образ** (`cc-runtime-minimal` — см. ниже; включает python3 для выполнения T5)

## Стратегия выбора образа

looper определяет образ контейнера в следующем порядке приоритетов (результат сохраняется
в `looper/.looper-state.json` после первого вызова и используется повторно):

| Приоритет | Источник | Примечания |
|-----------|----------|------------|
| 1 | Флаг `--image <image>` | Явное указание, наивысший приоритет; не записывается в кэш состояния |
| 2 | Кэш `.looper-state.json` | Повторно использует образ предыдущего вызова |
| 3 | `.devcontainer/devcontainer.json` | Автоматически читает стандартный образ проекта |
| 4 | Локальный `cc-runtime-minimal` | Ранее собранный или скачанный |
| 5 | Резервные инструкции | Выводит инструкции по получению `cc-runtime-minimal` |

### Получение cc-runtime-minimal

**Скачать (рекомендуется):**
```bash
docker pull easyfan/agents-slim:cc-runtime-minimal
docker tag easyfan/agents-slim:cc-runtime-minimal cc-runtime-minimal
```

**Собрать локально** (для аудита безопасности):
```bash
docker build -t cc-runtime-minimal assets/image/
```

Исходный код образа: [easyfan/agents-slim](https://github.com/easyfan/agents-slim)

## Разработка

### Evals

`evals/evals.json` содержит 10 тесткейсов, охватывающих разбор аргументов, разрешение целей,
обнаружение доступности Docker, ветки стратегии образа и выполнение T5:

| ID | Сценарий | Что проверяется |
|----|----------|-----------------|
| 1 | `/looper --plugin patterns` | Разбор аргументов, существование целевого пути, доступность Docker; graceful exit при отсутствии Docker; T5 запускается при наличии Docker (evals.json присутствует) |
| 2 | `/looper --plugin xyz_nonexistent_...` | Выводит "❌ target not found" при отсутствии `packer/<pkg>`; контейнер не запускается |
| 3 | `/looper --plugin patterns` (полный поток) | Находит `packer/patterns/`, запускает `install.sh`, строит чистую среду, выполняет T1–T3 |
| 4 | `/looper` (без аргументов) | Выводит руководство по использованию; Docker-операции не выполняются |
| 5 | `/looper --plugin patterns --image my-custom-registry:cc-runtime` | Флаг `--image` устанавливает стратегию user-specified (приоритет 1), пропускает обнаружение devcontainer и кэш |
| 6 | То же (с существующим `.looper-state.json`) | Читает кэшированный файл состояния, использует записанный образ без повторного обнаружения |
| 7 | Проверка вывода стратегии образа | Вывод содержит имя образа и метку стратегии (devcontainer / user-specified / fallback / cached) |
| 8 | T5 активен — `/looper --plugin patterns` (evals.json присутствует) | Step 4 внедряет eval runner + evals.json; при наличии Docker T5 выполняется и выводит EVAL_SUITE_RESULT |
| 9 | T5 пропущен — `disable_t5: true` в evals.json | Step 4 выводит "eval suite: skipped (disable_t5=true)"; строка T5 показывает ⏭️; общий результат не провальный |

### Отключение T5

Добавьте `"disable_t5": true` на верхний уровень `evals.json`, чтобы запретить looper
выполнять набор оценок в контейнере. Используется когда тестируемый инструмент — сам looper
(потребовался бы Docker-in-Docker) или другой инструмент, который не может работать в чистой среде.

```json
{
  "skill_name": "looper",
  "disable_t5": true,
  "evals": [ ... ]
}
```

Step 4 выведет `eval suite: skipped (disable_t5=true in evals.json)`. Общий результат
не помечается как FAIL.

Ручное тестирование (в сессии Claude Code):
```bash
/looper --plugin patterns     # eval 1
/looper                       # eval 4 — просмотр руководства
```

Запуск всех evals через eval loop skill-creator (если установлен):
```bash
python ~/.claude/skills/skill-creator/scripts/run_loop.py \
  --skill-path ~/.claude/commands/looper.md \
  --evals-path evals/evals.json
```

## Структура пакета

```
looper/
├── commands/looper.md          # устанавливается в ~/.claude/commands/
├── assets/
│   ├── config/.claude.json     # устанавливается в ~/.claude/looper/
│   └── image/                  # исходный код образа cc-runtime-minimal
│       ├── Dockerfile
│       └── .github/workflows/build-push.yml
├── evals/evals.json
├── install.sh
└── SKILL.md
```
