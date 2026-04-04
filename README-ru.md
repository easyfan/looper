# looper

Верификация при развёртывании для плагинов Claude Code — выполняет тесты установки,
точности триггеров и поведенческий набор оценок (T5) в чистом Docker CC-контейнере.
Используется как этап 5 конвейера skill-test.

## Установка

```bash
bash install.sh
# Предварительный просмотр без записи файлов
bash install.sh --dry-run
# Удалить установленные файлы
bash install.sh --uninstall
# Пользовательский каталог конфигурации Claude (флаг или переменная окружения)
bash install.sh --target=~/.claude
CLAUDE_DIR=~/.claude bash install.sh
```

Устанавливает:
- `skills/looper/ → ~/.claude/skills/looper/`

> ✅ **Проверено**: покрыто конвейером skill-test (looper Stage 5).

## Использование

```
/looper --plugin <name>                          # верифицировать packer/<name>/
/looper --plugin <name> --plan a                 # только план A (путь install.sh)
/looper --plugin <name> --plan b                 # только план B (путь claude plugin install)
/looper --plugin <name> --image <image>          # использовать явно указанный образ контейнера
/looper --help                                   # показать справку
```

## Требования

- **Docker** (должен быть доступен на хосте; при запуске в devcontainer looper обнаруживает это и завершается с подсказкой)
- **CC runtime образ** (`cc-runtime-minimal` — см. ниже; включает python3 для выполнения T5)

## Стратегия выбора образа

looper определяет образ контейнера в следующем порядке приоритетов (результат сохраняется
в `packer/<name>/.looper-state.json` после первого вызова и используется повторно):

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

## Тестовые планы

looper выполняет два независимых плана верификации. Используйте `--plan both` (по умолчанию)
для запуска всех тестов, или `--plan a` / `--plan b` для одного плана.

| План | Шаги | Что проверяется |
|------|------|-----------------|
| A | T2 (A1–A7) | Соответствие интерфейса `install.sh`, установка файлов, идемпотентность, удаление, dry-run |
| B | T2b (B1–B8) | Путь `claude plugin install` (marketplace / локальный `plugin.json`) |

Эти тесты выполняются всегда независимо от значения `--plan`:

| Тест | Что проверяется |
|------|-----------------|
| T0 | Валидация манифеста `plugin.json` (хост, однократно) |
| T1 | Доступность CC в контейнере |
| T3 | Точность срабатывания skill (один вызов `claude -p`) |
| T5 | Поведенческий набор оценок (выполняет `evals/evals.json` в контейнере; пропускается при `disable_t5: true`) |

## Разработка

### Evals

`evals/evals.json` содержит 7 тест-кейсов для текущего CLI с единственным флагом `--plugin`:

| ID | Сценарий | Что проверяется |
|----|----------|-----------------|
| 1 | `/looper --help` | Справочный текст содержит все четыре флага и хотя бы один пример использования; Docker не запускается |
| 2 | `/looper` (без аргументов) | Выводит руководство по использованию; Docker-операции не выполняются |
| 3 | `/looper --plugin xyz_nonexistent_...` | Выводит ошибку «плагин не найден»; контейнер не запускается |
| 4 | `/looper --plugin looper --plan a` | Только план A; результат T2b — skip |
| 5 | `/looper --plugin looper --plan b` | Только план B; результат T2 — skip |
| 6 | `/looper --plugin looper --image my-custom-registry:cc-runtime` | Флаг `--image`; стратегия user-specified; имя образа присутствует в выводе |
| 7 | `/looper --plugin looper` | Плагин не найден в контейнере; корректный вывод ошибки |

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

## Структура пакета

```
looper/
├── .claude-plugin/
│   ├── plugin.json             # манифест плагина
│   └── marketplace.json        # запись marketplace
├── DESIGN.md                   # заметки по архитектуре
├── skills/looper/
│   └── SKILL.md                # устанавливается в ~/.claude/skills/looper/
├── scripts/
│   ├── run.sh                  # основная логика верификации
│   └── run_eval_suite.py       # T5 eval runner (внедряется в контейнер)
├── assets/image/               # исходный код образа cc-runtime-minimal
│   ├── Dockerfile
│   └── .github/workflows/build-push.yml
├── test/
│   ├── test-a.sh               # хост-тесты плана A
│   ├── test-b.sh               # хост-тесты плана B
│   └── test-all.sh
├── evals/evals.json
├── install.sh
└── package.json
```
