#!/usr/bin/env bash
# =============================================================================
#  install.sh — самодостатній інсталятор "Lecture Converter"
#               (mp4 -> mp3 -> md, ffmpeg + faster-whisper)
#
#  ДІЯ 1: ІНСТАЛЯЦІЯ З ОДНОГО ФАЙЛУ
#     Це єдиний файл, який потрібно мати. Він сам створює всі решту:
#       converter.py       головний скрипт конвертації
#       converter.env      конфігурація
#       requirements.txt   перелік залежностей Python
#       assets/beep.wav    сигнал про завершення
#       USAGE.md           інструкція з експлуатації
#       venv/              ізольоване середовище Python
#       models/            кеш ваг Whisper
#       ~/.local/bin/lecture-converter   команда-обгортка
#
#  ДІЯ 2: ЕКСПЛУАТАЦІЯ
#     lecture-converter                 -> довідка
#     lecture-converter lecture01.mp4   -> повний цикл конвертації
#     Детально — у згенерованому README.md
#
#  Запуск:  bash install.sh
#  Опції:   --no-model      не завантажувати ваги моделі зараз
#           --model NAME    інша модель (tiny|base|small|medium|large-v3)
#           --yes | -y      неінтерактивний режим
#           --emit-only     лише згенерувати файли, без apt/venv/моделі
#           --help | -h     ця довідка
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Константи
# -----------------------------------------------------------------------------

# Директорія самого install.sh стає директорією проєкту. Інсталяція
# не залежить від того, з якої папки скрипт запустили.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENV_DIR="${PROJECT_DIR}/venv"
MODELS_DIR="${PROJECT_DIR}/models"
ASSETS_DIR="${PROJECT_DIR}/assets"
CONFIG_FILE="${PROJECT_DIR}/converter.env"
CONVERTER_PY="${PROJECT_DIR}/converter.py"
USAGE_FILE="${PROJECT_DIR}/USAGE.md"
REQ_FILE="${PROJECT_DIR}/requirements.txt"
LAUNCHER_DIR="${HOME}/.local/bin"
LAUNCHER="${LAUNCHER_DIR}/lecture-converter"

VERSION="1.0.0"            # версія інсталятора; синхронізована з CHANGELOG.md
WHISPER_MODEL="large-v3"   # story #8: найбільша модель
DOWNLOAD_MODEL=1
ASSUME_YES=0
EMIT_ONLY=0

# Системні пакети:
#   ffmpeg             — конвертація mp4 -> mp3 (story #4)
#   python3/venv/pip   — середовище виконання (story #5)
#   alsa-utils         — aplay для сигналу (story #11)
#   pulseaudio-utils   — paplay, основний шлях на десктопній Ubuntu
#   curl/ca-certs      — завантаження ваг з Hugging Face
APT_PACKAGES=(ffmpeg python3 python3-venv python3-pip
              alsa-utils pulseaudio-utils ca-certificates curl)

# Python-залежності. faster-whisper обрано замість openai-whisper:
# він у 3-4 рази швидший на CPU і не тягне за собою torch (~2.5 ГБ).
PY_PACKAGES=(
  "faster-whisper>=1.0.3"
  "ctranslate2>=4.4.0"
  "av>=12.0.0"
  "huggingface-hub>=0.24.0"
  "tqdm>=4.66.0"
)

# -----------------------------------------------------------------------------
# 1. Функції виводу
# -----------------------------------------------------------------------------

step()  { printf '\n==> %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    [ OK ] %s\n' "$*"; }
warn()  { printf '    [ !  ] %s\n' "$*" >&2; }
fail()  { printf '\n[ ПОМИЛКА ] %s\n' "$*" >&2; exit 1; }

# Питання з відповіддю за замовчуванням "так".
ask() {
  local prompt="$1" answer
  if [ "${ASSUME_YES}" -eq 1 ]; then
    info "${prompt} -> так (режим --yes)"
    return 0
  fi
  read -r -p "    ${prompt} [Y/n] " answer
  case "${answer}" in
    ""|y|Y|yes|Yes|т|Т|так|Так) return 0 ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# 2. Аргументи
# -----------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --no-model)  DOWNLOAD_MODEL=0; shift ;;
    --model)     WHISPER_MODEL="${2:?--model потребує назви моделі}"; shift 2 ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --emit-only) EMIT_ONLY=1; ASSUME_YES=1; DOWNLOAD_MODEL=0; shift ;;
    --help|-h)   sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) fail "Невідомий аргумент: $1 (спробуйте --help)" ;;
  esac
done

printf '===============================================================\n'
printf ' Lecture Converter — інсталяція, версія %s\n' "${VERSION}"
printf ' Проєкт: %s\n' "${PROJECT_DIR}"
printf ' Модель: %s\n' "${WHISPER_MODEL}"
[ "${EMIT_ONLY}" -eq 1 ] && printf ' Режим:  --emit-only (лише генерація файлів)\n'
printf '===============================================================\n'

# -----------------------------------------------------------------------------
# 3. Перевірка оточення
# -----------------------------------------------------------------------------

step "Крок 1/9. Перевірка операційної системи"

if [ "${EMIT_ONLY}" -eq 1 ]; then
  info "Пропущено (--emit-only)."
else
  command -v apt-get >/dev/null 2>&1 || \
    fail "Не знайдено apt-get. Скрипт розрахований на Ubuntu/Debian (story #3)."

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "Дистрибутив: ${PRETTY_NAME:-невідомо}"
  fi

  # Права root потрібні лише для apt. Решта — у домашній директорії.
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    warn "Запуск від root: venv і launcher належатимуть root."
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    info "Системні пакети встановлюватимуться через sudo."
  else
    fail "Потрібен sudo для встановлення системних пакетів."
  fi

  # Місце на диску: large-v3 ~3 ГБ, venv ~1 ГБ, запас на артефакти.
  AVAIL_MB=$(df -Pm "${PROJECT_DIR}" | awk 'NR==2 {print $4}')
  info "Вільно на диску: ${AVAIL_MB} МБ"
  if [ "${AVAIL_MB}" -lt 6000 ]; then
    warn "Рекомендовано щонайменше 6 ГБ."
    ask "Продовжити?" || fail "Скасовано користувачем."
  fi

  # Пам'ять: large-v3 в int8 займає близько 4 ГБ RAM.
  RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  info "Оперативна пам'ять: ${RAM_MB} МБ"
  if [ "${RAM_MB}" -lt 8000 ] && [ "${WHISPER_MODEL}" = "large-v3" ]; then
    warn "Для large-v3 бажано 8+ ГБ RAM. Альтернатива: --model medium."
  fi

  ok "Оточення придатне."
fi

# -----------------------------------------------------------------------------
# 4. Системні пакети
# -----------------------------------------------------------------------------

step "Крок 2/9. Системні пакети (apt)"

if [ "${EMIT_ONLY}" -eq 1 ]; then
  info "Пропущено (--emit-only)."
else
  MISSING=()
  for pkg in "${APT_PACKAGES[@]}"; do
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
      info "вже встановлено: ${pkg}"
    else
      info "буде встановлено: ${pkg}"
      MISSING+=("${pkg}")
    fi
  done

  if [ ${#MISSING[@]} -gt 0 ]; then
    if ask "Встановити ${#MISSING[@]} пакет(ів)?"; then
      ${SUDO} apt-get update
      # DEBIAN_FRONTEND=noninteractive прибирає діалоги налаштування пакетів.
      ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING[@]}"
    else
      fail "Без системних пакетів робота неможлива."
    fi
  else
    info "Усі системні залежності на місці."
  fi

  command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg не знайдено після встановлення."
  ok "ffmpeg: $(ffmpeg -version | head -n1 | cut -c1-60)"
fi

# -----------------------------------------------------------------------------
# 5. Віртуальне середовище
# -----------------------------------------------------------------------------

step "Крок 3/9. Віртуальне середовище Python"

VENV_PY="${VENV_DIR}/bin/python"

if [ "${EMIT_ONLY}" -eq 1 ]; then
  info "Пропущено (--emit-only)."
else
  # venv обов'язковий: починаючи з Ubuntu 23.04 системний pip
  # заблокований політикою PEP 668 (externally-managed-environment).
  if [ -d "${VENV_DIR}" ]; then
    info "venv уже існує: ${VENV_DIR}"
    if ask "Перестворити з нуля?"; then
      rm -rf "${VENV_DIR}"
      python3 -m venv "${VENV_DIR}"
      ok "venv перестворено."
    fi
  else
    python3 -m venv "${VENV_DIR}"
    ok "venv створено: ${VENV_DIR}"
  fi
  info "Python: $("${VENV_PY}" --version)"
fi

# -----------------------------------------------------------------------------
# 6. Бібліотеки Python
# -----------------------------------------------------------------------------

step "Крок 4/9. Бібліотеки Python"

# requirements.txt пишемо завжди — він потрібен для відтворення
# інсталяції на іншій машині.
printf '%s\n' "${PY_PACKAGES[@]}" > "${REQ_FILE}"
info "Створено requirements.txt"

if [ "${EMIT_ONLY}" -eq 1 ]; then
  info "Встановлення пропущено (--emit-only)."
else
  info "Оновлення pip / setuptools / wheel..."
  "${VENV_PY}" -m pip install --upgrade pip setuptools wheel
  info "Встановлення: ${PY_PACKAGES[*]}"
  "${VENV_PY}" -m pip install -r "${REQ_FILE}"
  ok "Бібліотеки встановлено."
fi

# -----------------------------------------------------------------------------
# 7. Обчислювальний пристрій
# -----------------------------------------------------------------------------

step "Крок 5/9. Визначення обчислювального пристрою"

# int8 на CPU, float16 на GPU. У початковому драфті було "int7" —
# такого типу в CTranslate2 не існує, валідні: int8, int8_float16,
# float16, float32.
DEVICE="cpu"
COMPUTE_TYPE="int8"

if [ "${EMIT_ONLY}" -eq 0 ] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
  info "Виявлено NVIDIA GPU: ${GPU_NAME}"
  if ask "Використовувати GPU (потребує CUDA 12 + cuDNN 9)?"; then
    DEVICE="cuda"
    COMPUTE_TYPE="float16"
    info "Встановлення CUDA-бібліотек у venv (близько 1.4 ГБ)..."
    if "${VENV_PY}" -m pip install nvidia-cublas-cu12 nvidia-cudnn-cu12; then
      # Перевіряємо, що потрібні .so справді з'явилися. Пакети кладуть їх
      # у site-packages/nvidia/*/lib — ld.so про цей шлях не знає, тому
      # converter.py на старті сам додає його в LD_LIBRARY_PATH.
      CUBLAS_SO=$(find "${VENV_DIR}" -name "libcublas.so.12*" 2>/dev/null | head -n1)
      CUDNN_SO=$(find "${VENV_DIR}" -name "libcudnn.so.9*" 2>/dev/null | head -n1)
      if [ -n "${CUBLAS_SO}" ] && [ -n "${CUDNN_SO}" ]; then
        ok "libcublas.so.12 і libcudnn.so.9 на місці"
        info "Шлях: $(dirname "${CUBLAS_SO}")"
      else
        warn "Не знайдено libcublas.so.12 або libcudnn.so.9 — відкочуємось на CPU."
        DEVICE="cpu"; COMPUTE_TYPE="int8"
      fi
    else
      warn "Не вдалося встановити CUDA-бібліотеки. Відкочуємось на CPU."
      DEVICE="cpu"; COMPUTE_TYPE="int8"
    fi
  fi
else
  info "GPU не використовується — режим CPU."
fi

CPU_THREADS=$(nproc)
info "Пристрій: ${DEVICE} / ${COMPUTE_TYPE}, потоків CPU: ${CPU_THREADS}"

# -----------------------------------------------------------------------------
# 8. Конфігураційний файл
# -----------------------------------------------------------------------------

step "Крок 6/9. Конфігурація converter.env"

mkdir -p "${MODELS_DIR}" "${ASSETS_DIR}"

# Винесення параметрів у конфіг дозволяє змінювати поведінку
# без правки коду converter.py.
cat > "${CONFIG_FILE}" <<EOF
# Конфігурація Lecture Converter.
# Згенеровано install.sh $(date '+%Y-%m-%d %H:%M:%S'). Можна редагувати вручну.

# --- Модель Whisper ---------------------------------------------------------
WHISPER_MODEL=${WHISPER_MODEL}
MODELS_DIR=${MODELS_DIR}
DEVICE=${DEVICE}
COMPUTE_TYPE=${COMPUTE_TYPE}
CPU_THREADS=${CPU_THREADS}

# --- Розпізнавання ----------------------------------------------------------
# Порожня LANGUAGE = автовизначення. Для двомовних лекцій (story #9)
# автовизначення зазвичай доречніше за жорстко задану мову.
LANGUAGE=
VAD_FILTER=true

# --- Аудіо (параметри ffmpeg) -----------------------------------------------
# Whisper працює з 16 кГц моно; вищі значення точності не додають.
AUDIO_SAMPLE_RATE=16000
AUDIO_CHANNELS=1
AUDIO_BITRATE=64k

# --- Сигнал про завершення (story #11) --------------------------------------
BEEP_ENABLED=true
BEEP_FILE=${ASSETS_DIR}/beep.wav

# --- Поведінка з вихідним відео ---------------------------------------------
# false = відео копіюється в робочу папку (оригінал лишається на місці)
KEEP_ORIGINAL_IN_PLACE=false
EOF

ok "Записано converter.env"

# -----------------------------------------------------------------------------
# 9. Генерація converter.py
# -----------------------------------------------------------------------------

step "Крок 7/9. Генерація converter.py"

# Якщо файл уже є і був змінений — не затираємо мовчки.
if [ -f "${CONVERTER_PY}" ]; then
  warn "converter.py уже існує."
  if ask "Перезаписати (стару версію буде збережено як .bak)?"; then
    cp "${CONVERTER_PY}" "${CONVERTER_PY}.bak"
    info "Резервна копія: converter.py.bak"
  else
    info "Залишаємо наявний converter.py."
    SKIP_CONVERTER=1
  fi
fi

if [ "${SKIP_CONVERTER:-0}" -eq 0 ]; then
# Роздільник у лапках ('CONVERTER_PY_EOF') вимикає підстановку змінних
# усередині — код на Python потрапляє у файл без жодних змін.
cat > "${CONVERTER_PY}" <<'CONVERTER_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Lecture Converter — mp4 -> mp3 -> md

Призначення:
    Витягує звукову доріжку з відеозапису лекції, розпізнає мовлення
    моделлю Whisper і зберігає результат у Markdown для подальшого
    формування навчальних матеріалів.

Логіка роботи (одним запуском, story #6):
    1. Перевірка вхідного файлу та наявності інструментів.
    2. Створення робочої папки з назвою вихідного відеофайлу (story #2).
    3. Копіювання/перенесення відео до цієї папки.
    4. ffmpeg: mp4 -> mp3 (16 кГц, моно — оптимум для Whisper).
    5. faster-whisper: mp3 -> текст із часовими мітками.
    6. Запис Markdown із YAML front-matter.
    7. Звуковий сигнал про завершення (story #11).

Файл згенеровано install.sh. Правки вітаються — код навмисно
розгорнутий і закоментований для подальшого доопрацювання (story #5).
"""

import argparse
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# =============================================================================
#  РОЗДІЛ 1. Константи та шляхи
# =============================================================================

# Директорія, де лежить сам converter.py. Поруч із ним — converter.env,
# venv/ та models/. Так скрипт знаходить свою конфігурацію незалежно
# від того, з якої папки його викликали.
SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "converter.env"

# Розширення, які приймаємо на вхід. Формально ТЗ каже про mp4,
# але ffmpeg однаково добре впорається з рештою контейнерів.
VIDEO_EXTENSIONS = {".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v", ".mpg", ".mpeg"}

# Значення за замовчуванням — використовуються, якщо converter.env
# відсутній або в ньому бракує ключа.
DEFAULTS = {
    "WHISPER_MODEL": "large-v3",
    "MODELS_DIR": str(SCRIPT_DIR / "models"),
    "DEVICE": "cpu",
    "COMPUTE_TYPE": "int8",
    "CPU_THREADS": "0",           # 0 = хай вирішує CTranslate2
    "LANGUAGE": "",               # порожньо = автовизначення
    "VAD_FILTER": "true",
    "AUDIO_SAMPLE_RATE": "16000",
    "AUDIO_CHANNELS": "1",
    "AUDIO_BITRATE": "64k",
    "BEEP_ENABLED": "true",
    "BEEP_FILE": str(SCRIPT_DIR / "assets" / "beep.wav"),
    "KEEP_ORIGINAL_IN_PLACE": "false",   # false = відео копіюється в робочу папку
}

def find_cuda_lib_dirs(python_prefix: Path) -> list:
    """
    Знаходить директорії з CUDA-бібліотеками, встановленими через pip.

    Пакети nvidia-cublas-cu12 та nvidia-cudnn-cu12 кладуть свої .so
    не в /usr/lib, а всередину site-packages:

        venv/lib/python3.12/site-packages/nvidia/cublas/lib/libcublas.so.12
        venv/lib/python3.12/site-packages/nvidia/cudnn/lib/libcudnn.so.9

    Динамічний завантажувач ld.so про ці шляхи не знає, тому
    ctranslate2 падає з "Library libcublas.so.12 is not found".
    Повертаємо список директорій, які треба додати в LD_LIBRARY_PATH.
    """
    lib_dirs = []
    # Версія Python може відрізнятись, тому шукаємо за шаблоном.
    for site_packages in python_prefix.glob("lib/python*/site-packages"):
        nvidia_root = site_packages / "nvidia"
        if not nvidia_root.is_dir():
            continue
        # Кожен пакет має вигляд nvidia/<компонент>/lib/
        for lib_dir in sorted(nvidia_root.glob("*/lib")):
            if any(lib_dir.glob("*.so*")):
                lib_dirs.append(str(lib_dir))
    return lib_dirs


def bootstrap() -> None:
    """
    Готує середовище виконання і, за потреби, перезапускає скрипт.

    Виконує дві задачі, які обидві мають бути зроблені ДО старту
    процесу, а не після:

    1. Правильний інтерпретатор. Залежності (faster-whisper,
       ctranslate2) стоять лише у ./venv. Виклик `python3 converter.py`
       системним Python завершився б помилкою імпорту.

    2. LD_LIBRARY_PATH для CUDA. Змінну читає динамічний завантажувач
       у момент запуску процесу — змінювати її з уже запущеної програми
       марно. Саме тому тут os.execv(), а не просто os.environ[...].

    Захист від зациклення: змінна-маркер LECTURE_CONVERTER_RELAUNCH.
    Після одного перезапуску функція гарантовано нічого не робить.
    """
    if os.environ.get("LECTURE_CONVERTER_RELAUNCH") == "1":
        return

    venv_dir = SCRIPT_DIR / "venv"
    venv_python = venv_dir / "bin" / "python"
    in_venv = sys.prefix != sys.base_prefix

    # --- Що саме треба виправити ---
    need_venv_switch = (not in_venv) and venv_python.exists()

    # Шукаємо CUDA-бібліотеки там, де вони будуть після перемикання.
    prefix_for_search = venv_dir if (in_venv is False and venv_dir.exists()) else Path(sys.prefix)
    cuda_dirs = find_cuda_lib_dirs(prefix_for_search)

    current_ld = os.environ.get("LD_LIBRARY_PATH", "")
    current_parts = [p for p in current_ld.split(":") if p]
    missing_dirs = [d for d in cuda_dirs if d not in current_parts]

    # Якщо все вже на місці — працюємо далі без перезапуску.
    if not need_venv_switch and not missing_dirs:
        return

    # --- Формуємо нове оточення ---
    if missing_dirs:
        os.environ["LD_LIBRARY_PATH"] = ":".join(missing_dirs + current_parts)

    os.environ["LECTURE_CONVERTER_RELAUNCH"] = "1"

    interpreter = str(venv_python) if need_venv_switch else sys.executable

    # execv заміщує поточний процес: новий стартує вже з правильним
    # LD_LIBRARY_PATH, і ld.so знаходить libcublas/libcudnn.
    os.execv(interpreter,
             [interpreter, str(Path(__file__).resolve()), *sys.argv[1:]])


# =============================================================================
#  РОЗДІЛ 2. Функції виводу
#  Уся комунікація з користувачем зібрана тут, щоб її було легко
#  замінити (наприклад, на logging або на GUI) у наступних версіях.
# =============================================================================

_T_START = time.time()


def _elapsed() -> str:
    """Час від старту програми у форматі мм:сс — зручно бачити прогрес."""
    sec = int(time.time() - _T_START)
    return f"{sec // 60:02d}:{sec % 60:02d}"


def step(text: str) -> None:
    """Заголовок великого етапу роботи."""
    print(f"\n[{_elapsed()}] ==> {text}", flush=True)


def info(text: str) -> None:
    """Рядок деталізації всередині етапу."""
    print(f"          {text}", flush=True)


def ok(text: str) -> None:
    """Успішне завершення дії."""
    print(f"          [ OK ] {text}", flush=True)


def warn(text: str) -> None:
    """Попередження — робота триває."""
    print(f"          [ !  ] {text}", file=sys.stderr, flush=True)


def die(text: str, code: int = 1) -> None:
    """Фатальна помилка — виходимо з ненульовим кодом."""
    print(f"\n[ ПОМИЛКА ] {text}", file=sys.stderr, flush=True)
    sys.exit(code)


def hhmmss(seconds: float) -> str:
    """Секунди -> 'гг:хх:сс'. Використовується для часових міток у Markdown."""
    seconds = int(seconds)
    return f"{seconds // 3600:02d}:{(seconds % 3600) // 60:02d}:{seconds % 60:02d}"


# =============================================================================
#  РОЗДІЛ 3. Конфігурація
# =============================================================================

def load_config() -> dict:
    """
    Читає converter.env у простому форматі KEY=VALUE.

    Свідомо не використовуємо python-dotenv: формат тривіальний,
    а менше залежностей — простіше супроводжувати.
    """
    config = dict(DEFAULTS)

    if not CONFIG_PATH.exists():
        warn(f"Конфіг {CONFIG_PATH.name} не знайдено — беремо значення за замовчуванням.")
        return config

    for raw_line in CONFIG_PATH.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        # Пропускаємо порожні рядки та коментарі.
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        config[key.strip()] = value.strip()

    return config


def as_bool(value: str) -> bool:
    """Рядок із конфігу -> булеве значення."""
    return str(value).strip().lower() in {"1", "true", "yes", "on", "так"}


# =============================================================================
#  РОЗДІЛ 4. Довідка (story #13)
# =============================================================================

def print_guide() -> None:
    """
    Друкується при виклику без аргументів: `python3 converter.py`.
    Показує не лише синтаксис, а й що робити далі та де лежить результат.
    """
    config = load_config()
    print(f"""
===============================================================
  Lecture Converter — mp4 -> mp3 -> md
===============================================================

  ПРИЗНАЧЕННЯ
    Витягує звук із запису лекції та розпізнає його у Markdown,
    придатний для подальшої підготовки навчальних матеріалів.

  ЯК ЗАПУСТИТИ
    python3 converter.py <файл.mp4>
    lecture-converter <файл.mp4>          (якщо ставили через install.sh)

  ПРИКЛАДИ
    python3 converter.py lecture01.mp4
    python3 converter.py ~/Video/ПРВПЗ-лекція-3.mp4
    python3 converter.py lecture01.mp4 --language uk
    python3 converter.py lecture01.mp4 --model medium --force

  ЩО БУДЕ НА ВИХОДІ
    Поруч із відео створиться папка з його назвою, а в ній — три артефакти:

      lecture01/
        lecture01.mp4    вихідне відео
        lecture01.mp3    видобутий звук
        lecture01.md     розпізнаний текст із часовими мітками

  ПАРАМЕТРИ
    --language {{uk|en|auto}}  мова лекції (типово: auto)
    --model NAME             модель Whisper (типово: {config['WHISPER_MODEL']})
    --device {{cpu|cuda}}      обчислювальний пристрій (типово: {config['DEVICE']})
    --force                  перезаписати наявні mp3/md
    --move                   перенести відео у папку, а не копіювати
    --no-beep                без звукового сигналу в кінці
    --timestamps {{on|off}}    часові мітки у Markdown (типово: on)
    -h, --help               повна довідка argparse

  ПОТОЧНА КОНФІГУРАЦІЯ
    файл:     {CONFIG_PATH}
    модель:   {config['WHISPER_MODEL']}
    пристрій: {config['DEVICE']} / {config['COMPUTE_TYPE']}
    кеш:      {config['MODELS_DIR']}

  ОРІЄНТОВНИЙ ЧАС РОБОТИ
    На CPU модель large-v3 обробляє годину запису приблизно за
    40-90 хвилин (залежно від кількості ядер). На GPU — 3-8 хвилин.
    Щоб швидко перевірити роботу, спробуйте --model small.

===============================================================
""")


def build_parser() -> argparse.ArgumentParser:
    """Опис аргументів командного рядка (story #7)."""
    parser = argparse.ArgumentParser(
        prog="converter.py",
        description="Конвертація запису лекції: mp4 -> mp3 -> md (Whisper).",
    )
    parser.add_argument("video", help="шлях до відеофайлу (mp4, mkv, mov, ...)")
    parser.add_argument("--language", default=None,
                        help="мова: uk, en, auto (типово — з converter.env)")
    parser.add_argument("--model", default=None, help="модель Whisper")
    parser.add_argument("--device", default=None, choices=["cpu", "cuda"],
                        help="обчислювальний пристрій")
    parser.add_argument("--force", action="store_true",
                        help="перезаписати наявні mp3/md")
    parser.add_argument("--move", action="store_true",
                        help="перенести відео у робочу папку замість копіювання")
    parser.add_argument("--no-beep", action="store_true",
                        help="не подавати звуковий сигнал у кінці")
    parser.add_argument("--timestamps", default="on", choices=["on", "off"],
                        help="часові мітки у Markdown")
    return parser


# =============================================================================
#  РОЗДІЛ 5. Підготовка робочої папки (story #2)
# =============================================================================

def prepare_workspace(video: Path, move: bool) -> tuple:
    """
    Створює папку з назвою відеофайлу і розміщує там оригінал.

    Повертає кортеж (робоча_папка, шлях_до_відео_в_папці).

    Приклад: ~/Video/lecture01.mp4  ->  ~/Video/lecture01/lecture01.mp4
    """
    step("Етап 1/4. Підготовка робочої папки")

    stem = video.stem                      # ім'я файлу без розширення
    workdir = video.parent / stem          # папка поруч із оригіналом

    # Окремий випадок: відео вже лежить у папці зі своїм іменем —
    # тоді нічого не створюємо і не копіюємо.
    if video.parent.name == stem:
        info("Відео вже у власній папці — повторне вкладення не потрібне.")
        return video.parent, video

    workdir.mkdir(parents=True, exist_ok=True)
    info(f"Папка: {workdir}")

    target_video = workdir / video.name

    if target_video.exists() and target_video.samefile(video):
        info("Відео вже на місці.")
    elif target_video.exists():
        info("Відео у папці вже є — пропускаємо перенесення.")
    elif move:
        # Перенесення економить місце, але руйнує оригінальне розташування.
        shutil.move(str(video), str(target_video))
        ok(f"Відео перенесено: {target_video.name}")
    else:
        # Копіювання — безпечніший типовий режим: оригінал лишається цілим.
        size_mb = video.stat().st_size / 1024 / 1024
        info(f"Копіювання відео ({size_mb:.0f} МБ)...")
        shutil.copy2(str(video), str(target_video))
        ok(f"Відео скопійовано: {target_video.name}")

    return workdir, target_video


# =============================================================================
#  РОЗДІЛ 6. Видобування звуку через ffmpeg (story #4)
# =============================================================================

def extract_audio(video: Path, workdir: Path, config: dict, force: bool) -> Path:
    """
    mp4 -> mp3 засобами ffmpeg.

    Параметри кодування підібрані під Whisper, а не під прослуховування:
      -vn            прибрати відеопотік
      -ac 1          моно: Whisper однаково зводить канали в один
      -ar 16000      16 кГц — рідна частота дискретизації моделі
      -b:a 64k       достатньо для мовлення; більший бітрейт точності не додає
    """
    step("Етап 2/4. Видобування звуку (ffmpeg)")

    audio_path = workdir / f"{video.stem}.mp3"

    # Кешування проміжного результату: повторний запуск не витрачає час дарма.
    if audio_path.exists() and not force:
        size_mb = audio_path.stat().st_size / 1024 / 1024
        info(f"Файл {audio_path.name} вже існує ({size_mb:.1f} МБ) — пропускаємо.")
        info("Щоб перезаписати, додайте --force.")
        return audio_path

    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "warning",   # тихіше, ніж типово, але помилки видно
        "-stats",                 # рядок прогресу
        "-y",                     # перезаписувати без запитань
        "-i", str(video),
        "-vn",
        "-ac", config["AUDIO_CHANNELS"],
        "-ar", config["AUDIO_SAMPLE_RATE"],
        "-b:a", config["AUDIO_BITRATE"],
        str(audio_path),
    ]

    info(f"Команда: {' '.join(command)}")
    started = time.time()

    # check=False, щоб самостійно сформувати зрозуміле повідомлення про помилку.
    result = subprocess.run(command, check=False)
    if result.returncode != 0:
        die(f"ffmpeg завершився з кодом {result.returncode}. "
            f"Ймовірні причини: пошкоджений файл або відсутня звукова доріжка.")

    if not audio_path.exists() or audio_path.stat().st_size == 0:
        die("ffmpeg відпрацював, але файл mp3 порожній.")

    size_mb = audio_path.stat().st_size / 1024 / 1024
    ok(f"{audio_path.name} — {size_mb:.1f} МБ за {time.time() - started:.0f} с")
    return audio_path


# =============================================================================
#  РОЗДІЛ 7. Розпізнавання мовлення (story #4, #8, #9)
# =============================================================================

def transcribe(audio: Path, config: dict, args) -> tuple:
    """
    mp3 -> сегменти тексту засобами faster-whisper.

    Повертає (список_сегментів, метадані).

    Зауваження щодо двомовних лекцій (story #9): Whisper визначає мову
    один раз за початком запису і далі транскрибує в її рамках.
    Англіцизми всередині української мови розпізнаються добре — вони
    для моделі просто запозичені слова. А от якщо ви читаєте цілі блоки
    англійською всередині української лекції, є сенс або лишити
    автовизначення, або розділити запис і обробити частини окремо.
    """
    step("Етап 3/4. Розпізнавання мовлення (Whisper)")

    # Імпорт саме тут, а не вгорі файлу: бібліотека важка, і при виклику
    # довідки без аргументів вантажити її ні до чого.
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        # Показуємо реальний шлях до pip цього проєкту, а не абстрактний
        # приклад: так команду можна скопіювати без правок.
        die("Бібліотека faster-whisper недоступна.\n"
            f"  Поточний інтерпретатор: {sys.executable}\n"
            f"  Встановити:  {SCRIPT_DIR / 'venv' / 'bin' / 'pip'} "
            f"install -r {SCRIPT_DIR / 'requirements.txt'}\n"
            f"  Або перевстановити все:  bash {SCRIPT_DIR / 'install.sh'}")

    model_name = args.model or config["WHISPER_MODEL"]
    device = args.device or config["DEVICE"]
    compute_type = config["COMPUTE_TYPE"]

    # Якщо користувач вручну перемкнувся на CPU, float16 там не підтримується.
    if device == "cpu" and compute_type == "float16":
        warn("float16 недоступний на CPU — перемикаємось на int8.")
        compute_type = "int8"

    # Визначення мови: пріоритет у аргумента командного рядка.
    language = args.language if args.language is not None else config["LANGUAGE"]
    if language in ("", "auto", None):
        language = None
    info(f"Мова: {language if language else 'автовизначення'}")

    if model_name.startswith("large"):
        info("Перше завантаження large-моделі займе кілька хвилин (~3 ГБ).")

    # --- Внутрішня функція: одна спроба на заданому пристрої ---------------
    def attempt(dev: str, ctype: str):
        """
        Завантажує модель і повністю прогонює транскрибування.

        Винесено в окрему функцію, щоб мати змогу повторити спробу
        на іншому пристрої без дублювання коду.
        """
        info(f"Пристрій: {dev} / {ctype}")

        load_started = time.time()
        model = WhisperModel(
            model_name,
            device=dev,
            compute_type=ctype,
            download_root=config["MODELS_DIR"],
            cpu_threads=int(config.get("CPU_THREADS", "0") or 0),
        )
        ok(f"Модель готова за {time.time() - load_started:.0f} с")

        # transcribe() повертає ледачий генератор: реальна робота
        # почнеться під час ітерації, а не тут. Саме тому помилки CUDA
        # вигулькують не на цьому рядку, а всередині циклу нижче.
        segments_iter, meta = model.transcribe(
            str(audio),
            language=language,
            vad_filter=as_bool(config["VAD_FILTER"]),   # відкидає тишу
            vad_parameters={"min_silence_duration_ms": 500},
            beam_size=5,                        # компроміс точність/швидкість
            condition_on_previous_text=False,   # менше "залипання" на повторах
        )

        info(f"Тривалість запису: {hhmmss(meta.duration)}")
        info("Транскрибування розпочато.")

        collected = []
        started = time.time()
        last_report = 0.0
        language_reported = False

        for segment in segments_iter:
            # Мову модель визначає на першому сегменті, тому друкуємо
            # її тут, а не одразу після виклику transcribe().
            if not language_reported:
                info(f"Визначена мова: {meta.language} "
                     f"(впевненість {meta.language_probability:.0%})")
                language_reported = True

            collected.append(segment)

            # Прогрес не частіше ніж раз на 30 с аудіочасу.
            if segment.end - last_report >= 30:
                last_report = segment.end
                done = segment.end / meta.duration if meta.duration else 0
                elapsed = time.time() - started
                eta = (elapsed / done - elapsed) if done > 0.01 else 0
                info(f"  {hhmmss(segment.end)} / {hhmmss(meta.duration)} "
                     f"({done:.0%})  залишилось ~{hhmmss(eta)}")

        total = time.time() - started
        speed = meta.duration / total if total > 0 else 0
        ok(f"Розпізнано {len(collected)} сегментів за {hhmmss(total)} "
           f"(швидкість {speed:.1f}x реального часу)")
        return collected, meta

    # --- Спроба на обраному пристрої, за потреби — відкат на CPU -----------
    try:
        return attempt(device, compute_type)

    except RuntimeError as exc:
        message = str(exc)
        # Типові симптоми відсутніх або несумісних CUDA-бібліотек:
        #   Library libcublas.so.12 is not found or cannot be loaded
        #   Could not load library libcudnn_ops_infer.so.8
        #   CUDA failed with error ...
        cuda_markers = ("libcublas", "libcudnn", "CUDA", "cuda", "cuDNN")

        if device != "cuda" or not any(m in message for m in cuda_markers):
            die(f"Помилка під час розпізнавання: {exc}")

        warn(f"GPU недоступний: {message.splitlines()[0]}")
        warn("Переходимо на CPU. Це повільніше, але результат буде.")
        warn("Щоб не бачити цього щоразу, задайте DEVICE=cpu у converter.env.")

        try:
            return attempt("cpu", "int8")
        except Exception as cpu_exc:              # noqa: BLE001
            die(f"Не вдалося виконати розпізнавання і на CPU: {cpu_exc}")

    except Exception as exc:                      # noqa: BLE001
        die(f"Не вдалося виконати розпізнавання: {exc}")


# =============================================================================
#  РОЗДІЛ 8. Формування Markdown
# =============================================================================

def group_into_paragraphs(segments, max_chars: int = 700, pause: float = 1.5):
    """
    Зшиває короткі сегменти Whisper у читабельні абзаци.

    Whisper віддає репліки по 3-10 секунд. Для навчальних матеріалів
    зручніше мати абзаци: новий починається після помітної паузи
    або коли поточний абзац стає завеликим.
    """
    paragraphs = []
    buffer_text = []
    buffer_start = None
    previous_end = None

    for segment in segments:
        text = segment.text.strip()
        if not text:
            continue

        if buffer_start is None:
            buffer_start = segment.start

        # Умови розриву абзацу.
        gap_is_long = previous_end is not None and (segment.start - previous_end) > pause
        buffer_is_full = sum(len(t) for t in buffer_text) > max_chars

        if buffer_text and (gap_is_long or buffer_is_full):
            paragraphs.append((buffer_start, previous_end, " ".join(buffer_text)))
            buffer_text = []
            buffer_start = segment.start

        buffer_text.append(text)
        previous_end = segment.end

    if buffer_text:
        paragraphs.append((buffer_start, previous_end, " ".join(buffer_text)))

    return paragraphs


def write_markdown(segments, meta, video: Path, audio: Path,
                   workdir: Path, config: dict, args) -> Path:
    """
    Записує .md з YAML front-matter.

    Front-matter робить файл придатним для Obsidian, Hugo, Jekyll та
    інших інструментів, якими зручно вести базу навчальних матеріалів.
    """
    step("Етап 4/4. Формування Markdown")

    md_path = workdir / f"{video.stem}.md"
    paragraphs = group_into_paragraphs(segments)
    with_timestamps = args.timestamps == "on"

    lines = []

    # --- YAML front-matter ---
    lines.append("---")
    lines.append(f'title: "{video.stem}"')
    lines.append(f"source_video: {video.name}")
    lines.append(f"source_audio: {audio.name}")
    lines.append(f"duration: {hhmmss(meta.duration)}")
    lines.append(f"language: {meta.language}")
    lines.append(f"language_probability: {meta.language_probability:.3f}")
    lines.append(f"model: {args.model or config['WHISPER_MODEL']}")
    lines.append(f"device: {args.device or config['DEVICE']}")
    lines.append(f"transcribed_at: {datetime.now().isoformat(timespec='seconds')}")
    lines.append(f"segments: {len(segments)}")
    lines.append(f"paragraphs: {len(paragraphs)}")
    lines.append("status: draft   # draft | reviewed | published")
    lines.append("tags: [лекція, транскрипт]")
    lines.append("---")
    lines.append("")

    # --- Заголовок та службова інформація ---
    lines.append(f"# {video.stem}")
    lines.append("")
    lines.append(f"Тривалість: {hhmmss(meta.duration)} · "
                 f"Мова: {meta.language} · "
                 f"Модель: {args.model or config['WHISPER_MODEL']}")
    lines.append("")
    lines.append("> Автоматичний транскрипт. Потребує вичитки перед "
                 "використанням у навчальних матеріалах.")
    lines.append("")
    lines.append("## Транскрипт")
    lines.append("")

    # --- Тіло ---
    for start, end, text in paragraphs:
        if with_timestamps:
            # Мітка окремим рядком: не заважає читанню, але дозволяє
            # швидко знайти місце у відео.
            lines.append(f"**[{hhmmss(start)}]**")
            lines.append("")
        lines.append(text)
        lines.append("")

    # --- Місце для власних нотаток ---
    lines.append("## Нотатки")
    lines.append("")
    lines.append("<!-- Тут можна фіксувати тези, терміни, завдання для студентів. -->")
    lines.append("")

    md_path.write_text("\n".join(lines), encoding="utf-8")

    words = sum(len(text.split()) for _, _, text in paragraphs)
    ok(f"{md_path.name} — {len(paragraphs)} абзаців, ~{words} слів")
    return md_path


# =============================================================================
#  РОЗДІЛ 9. Звуковий сигнал (story #11)
# =============================================================================

def beep(config: dict, enabled: bool) -> None:
    """
    Сповіщає про завершення роботи.

    Чому не системний PC speaker: у сучасній Ubuntu модуль pcspkr
    зазвичай вимкнений, а символ \\a більшість терміналів ігнорує.
    Тому основний шлях — програвання заздалегідь згенерованого wav
    через paplay (PipeWire/PulseAudio) або aplay (ALSA), а \\a
    лишається запасним варіантом.
    """
    if not enabled or not as_bool(config["BEEP_ENABLED"]):
        return

    beep_file = Path(config["BEEP_FILE"])

    if beep_file.exists():
        for player in (["paplay"], ["aplay", "-q"]):
            if shutil.which(player[0]):
                try:
                    subprocess.run(player + [str(beep_file)],
                                   check=False, timeout=10,
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                    return
                except Exception:              # noqa: BLE001
                    continue

    # Запасний варіант: тричі подаємо символ дзвінка.
    for _ in range(3):
        sys.stdout.write("\a")
        sys.stdout.flush()
        time.sleep(0.25)


# =============================================================================
#  РОЗДІЛ 10. Точка входу
# =============================================================================

def main() -> int:
    # Найперша дія: перемикання на venv і налаштування LD_LIBRARY_PATH
    # для CUDA. Має бути до будь-яких важких імпортів.
    bootstrap()

    # Виклик без аргументів -> довідка (story #13).
    if len(sys.argv) == 1:
        print_guide()
        return 0

    args = build_parser().parse_args()
    config = load_config()

    print("=" * 63)
    print("  Lecture Converter — mp4 -> mp3 -> md")
    print("=" * 63)

    # --- Перевірки вхідних даних ---
    video = Path(args.video).expanduser().resolve()

    if not video.exists():
        die(f"Файл не знайдено: {video}")
    if not video.is_file():
        die(f"Це не файл: {video}")
    if video.suffix.lower() not in VIDEO_EXTENSIONS:
        warn(f"Незвичне розширення '{video.suffix}'. Пробуємо все одно.")
    if not shutil.which("ffmpeg"):
        die("ffmpeg не знайдено. Встановіть: sudo apt install ffmpeg")

    info(f"Вхідний файл: {video}")
    info(f"Розмір: {video.stat().st_size / 1024 / 1024:.0f} МБ")

    # --- Конвеєр (story #6: усі етапи з одного запуску) ---
    workdir, video_in_place = prepare_workspace(video, args.move)
    audio = extract_audio(video_in_place, workdir, config, args.force)

    md_path = workdir / f"{video.stem}.md"
    if md_path.exists() and not args.force:
        warn(f"{md_path.name} вже існує. Розпізнавання пропущено "
             f"(додайте --force для перезапису).")
    else:
        segments, meta = transcribe(audio, config, args)
        if not segments:
            die("Whisper не повернув жодного сегмента. "
                "Перевірте, чи є у записі мовлення.")
        md_path = write_markdown(segments, meta, video_in_place, audio,
                                 workdir, config, args)

    # --- Підсумок ---
    print("\n" + "=" * 63)
    print("  ГОТОВО")
    print("=" * 63)
    print(f"  Папка:  {workdir}")
    for artifact in sorted(workdir.iterdir()):
        if artifact.is_file():
            print(f"    {artifact.name:<40} {artifact.stat().st_size / 1024 / 1024:>8.1f} МБ")
    print(f"\n  Загальний час: {_elapsed()}")
    print("=" * 63)

    beep(config, enabled=not args.no_beep)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        # Ctrl+C — типова ситуація на довгих записах, обробляємо чемно.
        print("\n\nПерервано користувачем. Проміжні файли збережено.",
              file=sys.stderr)
        sys.exit(130)
CONVERTER_PY_EOF
chmod +x "${CONVERTER_PY}"
ok "Створено converter.py ($(wc -l < "${CONVERTER_PY}") рядків)"
fi

# --- Синтаксична перевірка згенерованого коду --------------------------------
# Робимо це одразу: краще виявити проблему тут, ніж під час першої лекції.
PY_FOR_CHECK="python3"
[ -x "${VENV_PY}" ] && PY_FOR_CHECK="${VENV_PY}"
if "${PY_FOR_CHECK}" -m py_compile "${CONVERTER_PY}" 2>/dev/null; then
  ok "Синтаксис converter.py коректний."
  rm -rf "${PROJECT_DIR}/__pycache__"
else
  warn "Не вдалося скомпілювати converter.py — перевірте вручну."
fi

# -----------------------------------------------------------------------------
# 10. README (дія 2: експлуатація)
# -----------------------------------------------------------------------------

step "Крок 8/9. Інструкція USAGE.md"

cat > "${USAGE_FILE}" <<EOF
# Lecture Converter — інструкція

Конвеєр обробки записів лекцій: \`mp4 -> mp3 -> md\`.
Звук видобувається через ffmpeg, текст розпізнається моделлю Whisper
(faster-whisper), результат зберігається у Markdown.

Згенеровано \`install.sh\` $(date '+%Y-%m-%d').

## Дія 1. Інсталяція

Потрібен лише файл \`install.sh\`:

\`\`\`bash
bash install.sh          # інтерактивно
bash install.sh --yes    # без запитань
bash install.sh --model medium --no-model
\`\`\`

Інсталятор створює: \`converter.py\`, \`converter.env\`,
\`requirements.txt\`, \`assets/beep.wav\`, \`venv/\`, \`models/\`
та команду \`lecture-converter\` у \`~/.local/bin\`.

## Дія 2. Експлуатація

\`\`\`bash
lecture-converter                          # довідка
lecture-converter lecture01.mp4            # повний цикл
lecture-converter lecture01.mp4 --language uk
lecture-converter lecture01.mp4 --model small --force
\`\`\`

Без команди-обгортки — обидва варіанти рівноцінні:

\`\`\`bash
cd ${PROJECT_DIR}
python3 converter.py lecture01.mp4        # сам перемкнеться на venv
./venv/bin/python converter.py lecture01.mp4
\`\`\`

Активувати venv вручну (\`source venv/bin/activate\`) не потрібно:
\`converter.py\` на старті визначає, що його запустили системним
інтерпретатором, і перезапускає себе під venv.

### Результат

Поруч із відео створюється папка з його назвою і трьома артефактами:

\`\`\`
lecture01/
  lecture01.mp4   вихідне відео
  lecture01.mp3   видобутий звук (16 кГц, моно, 64 kbps)
  lecture01.md    транскрипт із YAML front-matter і часовими мітками
\`\`\`

### Параметри

| Параметр | Призначення |
|---|---|
| \`--language uk\|en\|auto\` | мова лекції, типово auto |
| \`--model NAME\` | модель Whisper для цього запуску |
| \`--device cpu\|cuda\` | обчислювальний пристрій |
| \`--force\` | перезаписати наявні mp3/md |
| \`--move\` | перенести відео у папку, а не копіювати |
| \`--no-beep\` | без звукового сигналу |
| \`--timestamps on\|off\` | часові мітки у Markdown |

## Конфігурація

Постійні налаштування — у \`converter.env\`. Поточні значення:
модель \`${WHISPER_MODEL}\`, пристрій \`${DEVICE}\`, тип обчислень
\`${COMPUTE_TYPE}\`.

## Продуктивність

| Пристрій | Модель | Година запису |
|---|---|---|
| CPU (8 ядер) | large-v3 / int8 | 40-90 хв |
| CPU (8 ядер) | medium / int8 | 20-35 хв |
| CPU (8 ядер) | small / int8 | 8-15 хв |
| GPU (NVIDIA) | large-v3 / float16 | 3-8 хв |

Для перевірки роботи на новому записі зручно спершу прогнати
\`--model small\`, а вже потім — повну модель.

## Двомовні лекції

Whisper визначає мову один раз за початком запису. Англіцизми
всередині української розпізнаються нормально — модель сприймає їх
як запозичення. Якщо ж англійською читаються цілі блоки, доцільно
або лишити автовизначення, або розділити запис і обробити частини
окремо, задавши \`--language\` явно.

## Типові проблеми

**\`lecture-converter: command not found\`** — додайте до \`~/.bashrc\`:
\`export PATH="\$HOME/.local/bin:\$PATH"\`, потім \`source ~/.bashrc\`.

**Процес завершується без повідомлення** — найімовірніше брак RAM
на large-v3. Перейдіть на \`--model medium\`.

**\`Could not load libcudnn\`** — CUDA-бібліотеки не знайдені.
Або поставте їх, або задайте \`DEVICE=cpu\` у \`converter.env\`.

**Немає звукового сигналу** — перевірте \`paplay assets/beep.wav\`.

## Структура проєкту

\`\`\`
${PROJECT_DIR}/
  install.sh          інсталятор (самодостатній)
  converter.py        головний скрипт
  converter.env       конфігурація
  requirements.txt    залежності Python
  USAGE.md            інструкція (цей файл)
  README.md           опис репозиторію
  assets/beep.wav     сигнал завершення
  models/             кеш ваг Whisper
  venv/               віртуальне середовище
\`\`\`
EOF

ok "Створено USAGE.md"

# -----------------------------------------------------------------------------
# 11. Звуковий сигнал
# -----------------------------------------------------------------------------

step "Крок 9/9. Сигнал про завершення"

# Системний PC speaker у сучасній Ubuntu майже завжди вимкнений
# (модуль pcspkr у чорному списку), а символ \a термінали ігнорують.
# Надійніший шлях — короткий wav, згенерований ffmpeg, і paplay/aplay.
BEEP_FILE="${ASSETS_DIR}/beep.wav"
if [ ! -f "${BEEP_FILE}" ] && command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=880:duration=0.18" \
    -f lavfi -i "sine=frequency=1320:duration=0.18" \
    -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1[out]" \
    -map "[out]" -ar 44100 -ac 1 "${BEEP_FILE}"
  ok "Створено assets/beep.wav"
elif [ -f "${BEEP_FILE}" ]; then
  info "assets/beep.wav уже існує."
else
  warn "ffmpeg недоступний — beep.wav не створено."
fi

if command -v paplay >/dev/null 2>&1; then
  info "Програвач: paplay (PipeWire/PulseAudio)"
elif command -v aplay >/dev/null 2>&1; then
  info "Програвач: aplay (ALSA)"
else
  warn "paplay/aplay не знайдено — буде використано символ \\a."
fi

# -----------------------------------------------------------------------------
# 12. Завантаження ваг моделі
# -----------------------------------------------------------------------------

step "Додатково. Ваги моделі ${WHISPER_MODEL}"

if [ "${DOWNLOAD_MODEL}" -eq 1 ]; then
  info "Ваги буде збережено у ${MODELS_DIR} (large-v3 ~ 3 ГБ)."
  if ask "Завантажити зараз? (інакше — при першому запуску)"; then
    # Конструктор WhisperModel сам підтягує ваги з Hugging Face
    # у директорію download_root.
    "${VENV_PY}" - <<PYEOF
import sys
from faster_whisper import WhisperModel
print("    Завантаження та ініціалізація...")
try:
    WhisperModel("${WHISPER_MODEL}", device="${DEVICE}",
                 compute_type="${COMPUTE_TYPE}", download_root="${MODELS_DIR}")
    print("    Модель готова.")
except Exception as exc:
    print(f"    Помилка: {exc}", file=sys.stderr)
    sys.exit(1)
PYEOF
    ok "Модель у локальному кеші."
  else
    info "Пропущено."
  fi
else
  info "Пропущено (--no-model або --emit-only)."
fi

# -----------------------------------------------------------------------------
# 13. Команда-обгортка
# -----------------------------------------------------------------------------

step "Додатково. Команда lecture-converter"

if [ "${EMIT_ONLY}" -eq 1 ]; then
  info "Пропущено (--emit-only)."
else
  # Обгортка дозволяє викликати конвертер з будь-якої директорії
  # без ручної активації venv.
  mkdir -p "${LAUNCHER_DIR}"
  cat > "${LAUNCHER}" <<EOF
#!/usr/bin/env bash
# Автозгенеровано install.sh. Запускає converter.py у власному venv.
exec "${VENV_PY}" "${CONVERTER_PY}" "\$@"
EOF
  chmod +x "${LAUNCHER}"
  ok "Створено ${LAUNCHER}"

  # У стандартній Ubuntu ~/.local/bin потрапляє в PATH автоматично,
  # але лише якщо директорія існувала на момент входу в систему.
  case ":${PATH}:" in
    *":${LAUNCHER_DIR}:"*) info "${LAUNCHER_DIR} уже в PATH." ;;
    *) warn "Додайте до ~/.bashrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
fi

# -----------------------------------------------------------------------------
# 14. Самоперевірка
# -----------------------------------------------------------------------------

step "Самоперевірка"

CHECKS_OK=1
check() {  # check "опис" команда...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "${label}"
  else warn "${label} — не пройдено"; CHECKS_OK=0; fi
}

[ "${EMIT_ONLY}" -eq 0 ] && check "ffmpeg працює" ffmpeg -version
[ "${EMIT_ONLY}" -eq 0 ] && check "faster_whisper імпортується" "${VENV_PY}" -c "import faster_whisper"
check "converter.py на місці" test -f "${CONVERTER_PY}"

# Димовий тест: запускаємо converter.py саме системним python3.
# Це перевіряє ключове — що скрипт сам перемикається на venv і
# бачить свої залежності. Без аргументів він друкує довідку і виходить.
if [ "${EMIT_ONLY}" -eq 0 ]; then
  if python3 "${CONVERTER_PY}" >/dev/null 2>&1; then
    ok "python3 converter.py запускається і бачить venv"
  else
    warn "python3 converter.py не відпрацював — перевірте вручну"
    CHECKS_OK=0
  fi
fi

check "converter.env на місці" test -f "${CONFIG_FILE}"
check "USAGE.md на місці" test -f "${USAGE_FILE}"
check "beep.wav на місці" test -f "${BEEP_FILE}"

# -----------------------------------------------------------------------------
# 15. Підсумок
# -----------------------------------------------------------------------------

printf '\n===============================================================\n'
if [ "${CHECKS_OK}" -eq 1 ]; then
  printf ' ІНСТАЛЯЦІЮ ЗАВЕРШЕНО\n'
else
  printf ' ІНСТАЛЯЦІЮ ЗАВЕРШЕНО З ПОПЕРЕДЖЕННЯМИ (див. вище)\n'
fi
printf '===============================================================\n'
printf ' Створені файли:\n'
for f in converter.py converter.env requirements.txt USAGE.md assets/beep.wav; do
  [ -e "${PROJECT_DIR}/${f}" ] && printf '   %s\n' "${f}"
done
printf '\n Дія 2 — експлуатація:\n'
printf '   lecture-converter                  # довідка\n'
printf '   lecture-converter lecture01.mp4    # повний цикл\n'
printf '\n Детальніше: %s\n' "${USAGE_FILE}"
printf '===============================================================\n'

# Сигналимо тим самим механізмом, який використовує converter.py —
# заразом перевіряємо, що він працює.
if [ -f "${BEEP_FILE}" ]; then
  if command -v paplay >/dev/null 2>&1; then
    paplay "${BEEP_FILE}" 2>/dev/null || true
  elif command -v aplay >/dev/null 2>&1; then
    aplay -q "${BEEP_FILE}" 2>/dev/null || true
  else
    printf '\a'
  fi
else
  printf '\a'
fi
