# Свой LLM для Cursor

Self-hosted OpenAI-совместимый API на собственной (или арендованной) видеокарте, готовый к подключению в **[Cursor](https://cursor.com)** как кастомная модель. Совместим с любым другим клиентом, говорящим по протоколу OpenAI — Continue.dev, Cline, Aider, raw `curl` и т.д.

Запускает **[Qwen 2.5 Coder 32B Instruct](https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct-AWQ)** (AWQ INT4, ~22 ГБ VRAM) на **[vLLM](https://github.com/vllm-project/vllm)** и публикует через бесплатный **Cloudflare quick tunnel**, который даёт публичный HTTPS-URL без настройки DNS и сертификатов.

Полезно когда:

- работаете с кодом, который не хочется отправлять в коммерческие сервисы;
- хотите попробовать open-source модели в реальном рабочем процессе, а не в чатах для демо;
- упёрлись в лимиты Cursor Pro и ищете альтернативу с оплатой только за фактическую работу видеокарты.

## Что нужно

Linux с одной NVIDIA GPU от **24 ГБ VRAM** (RTX 4090, RTX A6000, A100 80 ГБ, H100 — все подходят) и актуальный CUDA-драйвер. Qwen 2.5 Coder 32B AWQ умещается в 24 ГБ с запасом на KV-кеш; для меньших карт (12–16 ГБ) переключите `MODEL_ID` на `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ`.

## Запуск

```bash
git clone https://github.com/cloudcompute-ru/cursor-llm.git
cd cursor-llm
bash provision.sh
```

Через 5–10 минут скрипт выведет три значения:

```
[cc-provision] provisioning complete
[cc-provision]   tunnel: https://three-random-words.trycloudflare.com
[cc-provision]   api key: sk-cc-<32 hex chars>
[cc-provision]   model name: qwen-2.5-coder-32b
```

Вставьте их в **Cursor → Settings → Models → Add custom model**:

| Поле Cursor | Что вставить                                                |
| ----------- | ----------------------------------------------------------- |
| Base URL    | `<tunnel URL>/v1` (например `https://...trycloudflare.com/v1`) |
| API Key     | строка `sk-cc-...`                                          |
| Model       | `qwen-2.5-coder-32b`                                        |

Включите модель и выберите её в селекторе моделей внизу окна Cursor. Теперь Tab, Chat и Composer работают через ваш GPU.

URL туннеля и API-ключ меняются при каждом перезапуске контейнера — особенность бесплатного quick tunnel. Для стабильного URL поднимите named-tunnel через свой Cloudflare-аккаунт (тот же `cloudflared`, другая команда), либо используйте one-click флоу на cloudcompute.ru (см. ниже).

### Переменные окружения

| Переменная          | По умолчанию                                | Что задаёт                                                  |
| ------------------- | ------------------------------------------- | ----------------------------------------------------------- |
| `MODEL_ID`          | `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ`       | HuggingFace ID модели для скачивания и сервинга.            |
| `SERVED_MODEL_NAME` | `qwen-2.5-coder-32b`                        | Имя модели, которое клиенты отправляют в `model:`.          |
| `VLLM_PORT`         | `8000`                                      | Внутренний порт vLLM. Туннель всегда указывает сюда.        |
| `WORKDIR`           | `/workspace`                                | Каталог для HF-кеша и runtime-состояния.                    |

## Что внутри

- `provision.sh` — ставит vLLM + cloudflared, скачивает Qwen 2.5 Coder, поднимает OpenAI-совместимый сервер на `0.0.0.0:8000`, открывает Cloudflare-туннель и выводит готовое подключение для Cursor.
- `screenshots/` — скриншоты интерфейса.

## Про cloudcompute.ru

Этот репозиторий поддерживает [cloudcompute.ru](https://cloudcompute.ru) — российский GPU-хостинг с почасовой оплатой. Если не хочется самостоятельно арендовать видеокарту и поднимать контейнер, [cloudcompute.ru/tutorials/cursor-llm](https://cloudcompute.ru/tutorials/cursor-llm) — это тот же скрипт, запущенный в один клик: подбор подходящей видеокарты от Vast.ai, оплата по факту работы (от ~80 ₽/час), готовая карточка с настройками для Cursor через 5–10 минут.

## Лицензии

Скрипты и конфигурация — MIT (см. `LICENSE`). Модель Qwen 2.5 Coder 32B распространяется под **Qwen License** (Alibaba) — коммерческое использование разрешено до 100M MAU. vLLM — Apache 2.0, cloudflared — Apache 2.0. Этот репозиторий устанавливает их в runtime, но не модифицирует и не перераспространяет.
