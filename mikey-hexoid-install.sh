#!/usr/bin/env bash
# mikey:hexoid – full installer v4.0.0
# Target: Debian inside Termux on ARM64 (aarch64)

set -e

BASE="$HOME/mikey-hexoid"
BIN="$BASE/bin"
CONF="$BASE/config"
HEX="$BASE/hex"
LIBS="$BASE/libs"
LOGS="$BASE/logs"
SKETCHES="$BASE/sketches"
TMPDIR="$BASE/tmp"
VENV="$BASE/venv"

# ---------- colors ----------
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[1;34m'
  CYAN='\033[1;36m'
  MAGENTA='\033[1;35m'
  RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; RESET=''
fi

info()  { echo -e "${CYAN}[mikey:hexoid]${RESET} $*"; }
ok()    { echo -e "${GREEN}[✔]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

echo -e "${MAGENTA}=== mikey:hexoid full installer v4.0.0 ===${RESET}"
info "Base directory: ${BASE}"

mkdir -p "$BIN" "$CONF" "$HEX" "$LIBS/arduino" "$LIBS/stm32" "$LOGS" "$SKETCHES" "$TMPDIR"

# ---------- apt deps ----------
info "Updating package index..."
sudo apt update -y

info "Installing base packages (python3, toolchains, etc.)..."
sudo apt install -y \
  python3 python3-venv python3-pip \
  git curl wget unzip zip p7zip-full \
  build-essential ca-certificates \
  gcc-arm-none-eabi binutils-arm-none-eabi \
  libnewlib-arm-none-eabi

# ---------- arduino-cli ----------
ARD_CLI="$BIN/arduino-cli"

install_arduino_cli() {
  local ARCH OS URL TAR
  ARCH="$(uname -m)"
  OS="Linux"

  case "$ARCH" in
    aarch64|arm64) ARCH="ARM64" ;;
    x86_64|amd64)  ARCH="64bit" ;;
    *) err "Unsupported arch: $ARCH"; exit 1 ;;
  esac

  URL="https://github.com/arduino/arduino-cli/releases/download/v1.3.1/arduino-cli_1.3.1_${OS}_${ARCH}.tar.gz"
  TAR="$TMPDIR/arduino-cli.tar.gz"

  info "Downloading arduino-cli (ARM64 v1.3.1)..."
  rm -f "$TAR"
  curl -L "$URL" -o "$TAR"

  info "Extracting arduino-cli..."
  tar -xvf "$TAR" -C "$BIN" >/dev/null 2>&1
  rm -f "$TAR"
  chmod +x "$BIN/arduino-cli"
  ok "arduino-cli installed to $BIN"
}

if [ -x "$ARD_CLI" ]; then
  ok "arduino-cli already present at $ARD_CLI"
else
  install_arduino_cli
fi

info "arduino-cli version:"
"$ARD_CLI" version || warn "arduino-cli version check failed (but binary exists)"

# ---------- arduino-cli config ----------
CLI_CFG="$CONF/arduino-cli.yaml"

cat >"$CLI_CFG" <<EOF
board_manager:
  additional_urls:
    - https://mcudude.github.io/MiniCore/package_MCUdude_MiniCore_index.json
    - https://mcudude.github.io/MegaCore/package_MCUdude_MegaCore_index.json
    - https://mcudude.github.io/MightyCore/package_MCUdude_MightyCore_index.json
    - https://mcudude.github.io/MicroCore/package_MCUdude_MicroCore_index.json
    - https://raw.githubusercontent.com/damellis/attiny/ide-1.6.x-boards-manager/package_damellis_attiny_index.json
    - http://drazzy.com/package_drazzy.com_index.json
    - https://raw.githubusercontent.com/stm32duino/BoardManagerFiles/main/package_stmicroelectronics_index.json
directories:
  data: $BASE/.arduino-data
  downloads: $BASE/.arduino-downloads
  user: $SKETCHES
logging:
  file: $LOGS/arduino-cli.log
  format: text
EOF

ok "arduino-cli config written to $CLI_CFG"

info "Updating Arduino core indices..."
if ! "$ARD_CLI" --config-file "$CLI_CFG" core update-index >>"$LOGS/core-update.log" 2>&1; then
  warn "Some indices failed to update; see $LOGS/core-update.log"
fi

# Base AVR core
info "Installing Arduino AVR core (arduino:avr)..."
if ! "$ARD_CLI" --config-file "$CLI_CFG" core install arduino:avr >>"$LOGS/core-install-arduino-avr.log" 2>&1; then
  warn "arduino:avr core install failed; see $LOGS/core-install-arduino-avr.log"
else
  ok "Arduino AVR core installed"
fi

# Extra AVR cores for many MCUs
for CORE in "MiniCore:avr" "MegaCore:avr" "MightyCore:avr" "MicroCore:avr" "attiny:avr"; do
  info "Installing extra AVR core: $CORE ..."
  if ! "$ARD_CLI" --config-file "$CLI_CFG" core install "$CORE" >>"$LOGS/core-install-${CORE//:/-}.log" 2>&1; then
    warn "Core $CORE failed to install (maybe not ARM64-ready). See $LOGS/core-install-${CORE//:/-}.log"
  else
    ok "Core $CORE installed"
  fi
done

# ---------- Python venv + libs ----------
info "Creating Python venv at $VENV..."
python3 -m venv "$VENV"
# shellcheck disable=SC1090
source "$VENV/bin/activate"
info "Installing Python helper libraries (rich, pygments, pyserial)..."
pip install --upgrade pip >/dev/null
pip install rich pygments pyserial >/dev/null
deactivate
ok "Python helper libs installed"

# ---------- STM32 Mikey Core files ----------
STM32_CORE_H="$LIBS/stm32/mikey_core.h"
STM32_CORE_C="$LIBS/stm32/mikey_core.c"
STM32_MAIN_C="$LIBS/stm32/mikey_main.c"
STM32_LD="$LIBS/stm32/stm32f103c8t6.ld"

info "Writing STM32 Mikey Core (Arduino-like, MCU-style pins)..."

cat >"$STM32_CORE_H" <<'EOF'
#ifndef MIKEY_CORE_H
#define MIKEY_CORE_H

#include <stdint.h>

/*
 * mikey STM32 Core – Arduino-like API for STM32F103C8 ("Bluepill")
 * Pin style: PA0, PA1, ..., PB0, ..., PC13 etc.
 */

#ifdef __cplusplus
extern "C" {
#endif

// MCU pin enum (high nibble = port, low nibble = bit)
typedef enum {
    PA0 = 0x00, PA1, PA2, PA3, PA4, PA5, PA6, PA7, PA8, PA9, PA10, PA11, PA12, PA13, PA14, PA15,
    PB0 = 0x10, PB1, PB2, PB3, PB4, PB5, PB6, PB7, PB8, PB9, PB10, PB11, PB12, PB13, PB14, PB15,
    PC0 = 0x20, PC1, PC2, PC3, PC4, PC5, PC6, PC7, PC8, PC9, PC10, PC11, PC12, PC13, PC14, PC15
} PinName;

#define HIGH 1
#define LOW  0

#define INPUT  0
#define OUTPUT 1

void mikey_init(void);

void pinMode(PinName pin, int mode);
void digitalWrite(PinName pin, int value);
int  digitalRead(PinName pin);

int  analogRead(PinName pin);              // simple stub (0–1023)
void analogWrite(PinName pin, int value);  // simple stub: value>0 => HIGH

void delay(unsigned long ms);
unsigned long millis(void);

// Arduino-like hook
void setup(void);
void loop(void);

#ifdef __cplusplus
}
#endif
#endif
EOF

cat >"$STM32_CORE_C" <<'EOF'
#include "mikey_core.h"

#define PERIPH_BASE     0x40000000UL
#define APB2PERIPH_BASE (PERIPH_BASE + 0x10000UL)
#define AHBPERIPH_BASE  (PERIPH_BASE + 0x20000UL)

#define GPIOA_BASE      (APB2PERIPH_BASE + 0x0800UL)
#define GPIOB_BASE      (APB2PERIPH_BASE + 0x0C00UL)
#define GPIOC_BASE      (APB2PERIPH_BASE + 0x1000UL)
#define RCC_BASE        (APB2PERIPH_BASE + 0x0000UL)
#define SYSTICK_BASE    0xE000E010UL

#define RCC_APB2ENR     (*(volatile uint32_t *)(RCC_BASE + 0x18UL))

#define GPIO_CRL(base)  (*(volatile uint32_t *)((base) + 0x00UL))
#define GPIO_CRH(base)  (*(volatile uint32_t *)((base) + 0x04UL))
#define GPIO_IDR(base)  (*(volatile uint32_t *)((base) + 0x08UL))
#define GPIO_ODR(base)  (*(volatile uint32_t *)((base) + 0x0CUL))

#define SYST_CSR        (*(volatile uint32_t *)(SYSTICK_BASE + 0x00UL))
#define SYST_RVR        (*(volatile uint32_t *)(SYSTICK_BASE + 0x04UL))
#define SYST_CVR        (*(volatile uint32_t *)(SYSTICK_BASE + 0x08UL))

static volatile unsigned long _mikey_ms = 0;

// very simple SysTick handler for millis()
void SysTick_Handler(void) {
    _mikey_ms++;
}

static void systick_init(void) {
    // assume 8 MHz core -> reload for 1ms tick: 8000 - 1
    SYST_RVR = 8000UL - 1UL;
    SYST_CVR = 0;
    SYST_CSR = 0x07; // ENABLE | TICKINT | CLKSOURCE
}

static inline uintptr_t pin_port_base(PinName pin) {
    uint8_t port = ((uint8_t)pin) >> 4;
    switch (port) {
        case 0: return GPIOA_BASE;
        case 1: return GPIOB_BASE;
        case 2: return GPIOC_BASE;
        default: return GPIOC_BASE;
    }
}

static inline uint8_t pin_bit(PinName pin) {
    return ((uint8_t)pin) & 0x0F;
}

void mikey_init(void) {
    // enable GPIOA/B/C clock bits: IOPAEN=2, IOPBEN=3, IOPCEN=4
    RCC_APB2ENR |= (1U << 2) | (1U << 3) | (1U << 4);
    systick_init();
}

void pinMode(PinName pin, int mode) {
    uintptr_t base = pin_port_base(pin);
    uint8_t bit = pin_bit(pin);
    volatile uint32_t *cr;
    uint8_t shift;

    if (bit < 8) {
        cr = &GPIO_CRL(base);
        shift = bit * 4;
    } else {
        cr = &GPIO_CRH(base);
        shift = (bit - 8) * 4;
    }

    uint32_t val = *cr;
    val &= ~(0xFU << shift);

    if (mode == OUTPUT) {
        // 0b0010: 2 MHz push-pull
        val |= (0x2U << shift);
    } else {
        // input floating: 0b0100
        val |= (0x4U << shift);
    }
    *cr = val;
}

void digitalWrite(PinName pin, int value) {
    uintptr_t base = pin_port_base(pin);
    uint8_t bit = pin_bit(pin);
    volatile uint32_t *odr = &GPIO_ODR(base);

    if (value == HIGH)
        *odr |= (1U << bit);
    else
        *odr &= ~(1U << bit);
}

int digitalRead(PinName pin) {
    uintptr_t base = pin_port_base(pin);
    uint8_t bit = pin_bit(pin);
    volatile uint32_t *idr = &GPIO_IDR(base);
    return ((*idr & (1U << bit)) != 0) ? HIGH : LOW;
}

// simple stubs; real ADC/PWM would need more setup
int analogRead(PinName pin) {
    (void)pin;
    return 0;
}

void analogWrite(PinName pin, int value) {
    digitalWrite(pin, value > 0 ? HIGH : LOW);
}

unsigned long millis(void) {
    return _mikey_ms;
}

void delay(unsigned long ms) {
    unsigned long start = millis();
    while ((millis() - start) < ms) {
        __asm__("nop");
    }
}
EOF

cat >"$STM32_MAIN_C" <<'EOF'
#include <stdint.h>
#include "mikey_core.h"

/*
 * mikey_main.c
 * - Provides vector table + Reset_Handler that calls setup()/loop()
 * - User code lives in sketch.c with Arduino-style structure.
 */

void Reset_Handler(void);
void Default_Handler(void);

extern unsigned long _etext;
extern unsigned long _sdata;
extern unsigned long _edata;
extern unsigned long _sbss;
extern unsigned long _ebss;

__attribute__((section(".isr_vector")))
void (* const g_pfnVectors[])(void) = {
    (void (*)(void))((unsigned long)&_ebss), // initial SP
    Reset_Handler,      // Reset
    Default_Handler,    // NMI
    Default_Handler,    // HardFault
    Default_Handler,    // MemManage
    Default_Handler,    // BusFault
    Default_Handler,    // UsageFault
    0,0,0,0,
    Default_Handler,    // SVC
    Default_Handler,    // DebugMon
    0,
    Default_Handler,    // PendSV
    Default_Handler     // SysTick (we override weak symbol in mikey_core if needed)
};

void Reset_Handler(void) {
    unsigned long *src, *dst;

    // copy .data
    src = &_etext;
    dst = &_sdata;
    while (dst < &_edata) {
        *dst++ = *src++;
    }

    // zero .bss
    dst = &_sbss;
    while (dst < &_ebss) {
        *dst++ = 0;
    }

    // user init + main loop
    mikey_init();
    setup();
    while (1) {
        loop();
    }
}

void Default_Handler(void) {
    while (1) {}
}
EOF

cat >"$STM32_LD" <<'EOF'
/* Minimal linker script for STM32F103C8T6 (64KB flash, 20KB RAM) */

MEMORY
{
  FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 64K
  RAM   (rwx): ORIGIN = 0x20000000, LENGTH = 20K
}

_estack = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
  .isr_vector :
  {
    . = ALIGN(4);
    KEEP(*(.isr_vector))
    . = ALIGN(4);
  } > FLASH

  .text :
  {
    . = ALIGN(4);
    *(.text*)
    *(.rodata*)
    . = ALIGN(4);
    _etext = .;
  } > FLASH

  .data : AT ( _etext )
  {
    . = ALIGN(4);
    _sdata = .;
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } > RAM

  .bss :
  {
    . = ALIGN(4);
    _sbss = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } > RAM
}
EOF

ok "STM32 Mikey Core written"

# ---------- mhex Python CLI ----------
MHEX_PY="$BASE/mhex.py"

info "Writing mhex Python CLI..."

cat >"$MHEX_PY" <<'EOF'
#!/usr/bin/env python3
import os
import sys
import json
import shutil
import subprocess
from pathlib import Path
from datetime import datetime

# Try rich for colors; fallback to plain
try:
    from rich.console import Console
    from rich.panel import Panel
    from rich.progress import Progress, SpinnerColumn, TextColumn
    from rich.table import Table
    console = Console()
    USE_RICH = True
except Exception:
    USE_RICH = False
    console = None

BASE = Path(os.environ.get("MIKEY_HEXOID_BASE", str(Path.home() / "mikey-hexoid"))).expanduser()
BIN = BASE / "bin"
CONF = BASE / "config"
HEX = BASE / "hex"
LIBS = BASE / "libs"
LOGS = BASE / "logs"
SKETCHES = BASE / "sketches"

CLI_CFG = CONF / "arduino-cli.yaml"
ARD_CLI = BIN / "arduino-cli"
VENV = BASE / "venv"
CONFIG_JSON = CONF / "mikey-hexoid.json"

DEFAULT_EXTERNAL_HEX = "/storage/emulated/0/Android/media/hex files"


def cprint(text, style=None):
    if USE_RICH:
        console.print(text, style=style)
    else:
        print(text)


def run(cmd, cwd=None, log_file=None, capture=False):
    """Run a command and return CompletedProcess."""
    if log_file:
        with open(log_file, "a", encoding="utf-8") as lf:
            lf.write(f"$ {' '.join(cmd)}\n")
    try:
        result = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            text=True,
            capture_output=capture,
        )
        if log_file:
            with open(log_file, "a", encoding="utf-8") as lf:
                lf.write(result.stdout)
                lf.write(result.stderr)
        return result
    except FileNotFoundError:
        return None


# ---------- config ----------
def load_config():
    if CONFIG_JSON.exists():
        try:
            data = json.loads(CONFIG_JSON.read_text())
        except Exception:
            data = {}
    else:
        data = {}

    if "version" not in data:
        data["version"] = "4.0.0"
    data.setdefault("external_hex_dir", DEFAULT_EXTERNAL_HEX)
    data.setdefault("build_count", 0)
    data.setdefault("last_build_kind", None)
    data.setdefault("last_build_success", None)
    data.setdefault("last_build_time", None)
    data.setdefault("preferences", {"color": True, "show_progress": True})
    presets = data.setdefault("presets", {})

    # AVR presets
    presets.setdefault("uno",   {"type": "avr", "fqbn": "arduino:avr:uno"})
    presets.setdefault("nano",  {"type": "avr", "fqbn": "arduino:avr:nano"})
    presets.setdefault("mega",  {"type": "avr", "fqbn": "arduino:avr:mega"})
    presets.setdefault("micro", {"type": "avr", "fqbn": "arduino:avr:micro"})
    # MiniCore ATmega8A/8 (external 16MHz example)
    presets.setdefault("atmega8a", {
        "type": "avr",
        "fqbn": "MiniCore:avr:8",
        "board_options": "clock=16MHz_external"
    })
    # bare ATmega328P via MiniCore
    presets.setdefault("atmega328p-bare", {
        "type": "avr",
        "fqbn": "MiniCore:avr:328",
        "board_options": "clock=16MHz_external"
    })
    # example attiny85 via damellis core
    presets.setdefault("attiny85", {
        "type": "avr",
        "fqbn": "attiny:avr:ATtinyX5"
    })

    # STM32 presets (Mikey core + bare)
    presets.setdefault("bluepill", {
        "type": "stm32",
        "backend": "mikey",
        "mcu": "stm32f103c8"
    })
    presets.setdefault("f103-bare", {
        "type": "stm32",
        "backend": "bare",
        "mcu": "stm32f103c8"
    })

    return data


def save_config(cfg):
    CONFIG_JSON.write_text(json.dumps(cfg, indent=2))


# ---------- helpers ----------
def ensure_dirs():
    for p in [BASE, BIN, CONF, HEX, LIBS, LOGS, SKETCHES]:
        p.mkdir(parents=True, exist_ok=True)


def copy_hex_to_external(hex_path, cfg):
    ext = cfg.get("external_hex_dir") or DEFAULT_EXTERNAL_HEX
    target_dir = Path(ext)
    try:
        target_dir.mkdir(parents=True, exist_ok=True)
    except Exception as e:
        cprint(f"[WARN] Could not create external hex dir '{ext}': {e}", "yellow")
        return
    dst = target_dir / Path(hex_path).name
    try:
        shutil.copy2(hex_path, dst)
        cprint(f"Mirrored HEX/BIN -> {dst}", "cyan")
    except Exception as e:
        cprint(f"[WARN] Failed to mirror HEX/BIN: {e}", "yellow")


def show_compile_result(ok, kind, name, hex_path=None, cfg=None):
    cfg = cfg or load_config()
    cfg["build_count"] = int(cfg.get("build_count", 0)) + 1
    cfg["last_build_kind"] = kind
    cfg["last_build_success"] = bool(ok)
    cfg["last_build_time"] = int(datetime.now().timestamp())
    save_config(cfg)

    if ok:
        cprint(f"[✔] Compile OK", "green")
        if hex_path:
            cprint(f"HEX file: {hex_path}", "cyan")
            copy_hex_to_external(hex_path, cfg)
    else:
        cprint("[✖] Build failed.", "red")


def print_error_excerpt(stderr: str):
    if not stderr:
        return
    lines = stderr.strip().splitlines()
    excerpt = []
    for ln in lines:
        if "error:" in ln or "undefined reference" in ln:
            excerpt.append(ln)
        if len(excerpt) >= 5:
            break
    if not excerpt:
        excerpt = lines[:5]
    if USE_RICH:
        console.print(Panel("\n".join(excerpt), title="Compiler errors", style="red"))
    else:
        print("Compiler errors:")
        for ln in excerpt:
            print(ln)


# ---------- commands ----------
def cmd_doctor():
    ensure_dirs()
    cfg = load_config()
    if USE_RICH:
        title = f"mikey:hexoid doctor"
        console.print(Panel.fit("", title=title))
    cprint(f"BASE: {BASE}", "cyan")
    cprint(f"arduino-cli: {ARD_CLI}", "cyan")
    r = run([str(ARD_CLI), "version"], capture=True)
    if not r or r.returncode != 0:
        cprint("arduino-cli not working correctly.", "red")
    else:
        cprint(r.stdout.strip(), "green")

    cprint("\n$ arduino-cli core list", "cyan")
    r = run([str(ARD_CLI), "--config-file", str(CLI_CFG), "core", "list"], capture=True)
    if r and r.stdout:
        print(r.stdout.strip())

    # Tool checks
    for tool in ["arm-none-eabi-gcc"]:
        r = run([tool, "--version"], capture=True)
        if r and r.returncode == 0:
            cprint(f"{tool}: OK", "green")
        else:
            cprint(f"{tool}: NOT FOUND", "red")

    cprint("\nConfig JSON:", "cyan")
    print(json.dumps(cfg, indent=2))


def cmd_help():
    text = """[bold]mikey:hexoid – v4.0.0[/bold]

Core usage:
  mhex doctor
  mhex new <name>
  mhex compile <name> --preset <uno|nano|mega|atmega8a|...>

STM32 Mikey Core (Arduino-like, MCU-style pins):
  mhex stm32-mikey-init <name>
  mhex stm32-mikey-build <name>

STM32 bare-metal:
  mhex stm32-bare-init <name>
  mhex stm32-bare-build <name>

Conversion:
  mhex convert-arduino-to-stm32 <arduino_name> <stm32_name>
  mhex convert-stm32-to-arduino <stm32_name> <arduino_name>

Libraries:
  mhex libs
  mhex lib-add-zip

Config / stats:
  mhex config
  mhex config-hex-dir <path>
  mhex boards
  mhex stats
"""
    if USE_RICH:
        console.print(Panel(text, title="mikey:hexoid HELP"))
    else:
        print(text)


def cmd_new(name: str):
    ensure_dirs()
    sketch_dir = SKETCHES / name
    sketch_dir.mkdir(parents=True, exist_ok=True)
    sketch_file = sketch_dir / f"{name}.ino"
    if sketch_file.exists():
        cprint(f"Sketch already exists: {sketch_file}", "yellow")
        return
    sketch_file.write_text(
        "/* mikey:hexoid template */\n"
        "const int ledPin = 13;\n\n"
        "void setup() {\n"
        "  pinMode(ledPin, OUTPUT);\n"
        "}\n\n"
        "void loop() {\n"
        "  digitalWrite(ledPin, HIGH);\n"
        "  delay(500);\n"
        "  digitalWrite(ledPin, LOW);\n"
        "  delay(500);\n"
        "}\n"
    )
    cprint(f"Created sketch: {sketch_file}", "green")


def resolve_preset(cfg, preset_name):
    presets = cfg.get("presets", {})
    p = presets.get(preset_name)
    if not p:
        raise SystemExit(f"Unknown preset '{preset_name}'. Use 'mhex boards' to see list.")
    return p


def cmd_compile(argv):
    if len(argv) < 3:
        raise SystemExit("Usage: mhex compile <name> --preset <preset>  OR  --board <FQBN>")
    name = argv[2]
    fqbn = None
    board_opts = None
    preset_name = None

    # parse args
    i = 3
    while i < len(argv):
        if argv[i] == "--preset" and i + 1 < len(argv):
            preset_name = argv[i+1]
            i += 2
        elif argv[i] == "--board" and i + 1 < len(argv):
            fqbn = argv[i+1]
            i += 2
        else:
            i += 1

    cfg = load_config()
    kind = "avr"

    if preset_name:
        p = resolve_preset(cfg, preset_name)
        if p["type"] != "avr":
            raise SystemExit(f"Preset '{preset_name}' is not AVR-type.")
        fqbn = p["fqbn"]
        board_opts = p.get("board_options")

    if not fqbn:
        raise SystemExit("You must specify --preset <name> or --board <FQBN>")

    sketch_dir = SKETCHES / name
    if not sketch_dir.exists():
        raise SystemExit(f"Sketch folder not found: {sketch_dir}")
    ino_files = list(sketch_dir.glob("*.ino"))
    if not ino_files:
        raise SystemExit(f"No .ino file found in {sketch_dir}")

    out_dir = HEX / name
    out_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        str(ARD_CLI),
        "--config-file", str(CLI_CFG),
        "compile",
        "--fqbn", fqbn,
        "--output-dir", str(out_dir),
        str(sketch_dir),
    ]
    if board_opts:
        cmd += ["--board-options", board_opts]

    cprint(f"Build #{load_config().get('build_count', 0)+1} → AVR compile ({name})", "magenta")

    stderr_text = ""
    if USE_RICH and load_config()["preferences"].get("show_progress", True):
        with Progress(SpinnerColumn(), TextColumn("[progress.description]{task.description}"), console=console) as progress:
            task = progress.add_task("Compiling AVR sketch...", total=None)
            r = run(cmd, capture=True)
            progress.update(task, completed=1)
            if r is None:
                stderr_text = "arduino-cli not found"
                ok_flag = False
            else:
                stderr_text = r.stderr
                ok_flag = (r.returncode == 0)
    else:
        r = run(cmd, capture=True)
        if r is None:
            stderr_text = "arduino-cli not found"
            ok_flag = False
        else:
            stderr_text = r.stderr
            ok_flag = (r.returncode == 0)
            print(r.stdout)

    if not ok_flag:
        print_error_excerpt(stderr_text)
        show_compile_result(False, kind, name, None, cfg)
        return

    # find hex
    hex_candidates = list(out_dir.glob("*.hex"))
    hex_path = hex_candidates[0] if hex_candidates else None
    show_compile_result(True, kind, name, hex_path, cfg)


# ---------- STM32 bare-metal ----------
def stm32_bare_template(name: str) -> str:
    return f"""#include <stdint.h>

#define PERIPH_BASE     0x40000000U
#define APB2PERIPH_BASE (PERIPH_BASE + 0x10000U)
#define GPIOC_BASE      (APB2PERIPH_BASE + 0x1000U)
#define RCC_BASE        (APB2PERIPH_BASE + 0x0000U)

#define RCC_APB2ENR     (*(volatile uint32_t *)(RCC_BASE + 0x18U))
#define GPIOC_CRH       (*(volatile uint32_t *)(GPIOC_BASE + 0x04U))
#define GPIOC_ODR       (*(volatile uint32_t *)(GPIOC_BASE + 0x0CU))

static void delay(volatile uint32_t t) {{
    while (t--) __asm__ volatile("nop");
}}

int main(void) {{
    // enable GPIOC
    RCC_APB2ENR |= (1U << 4);
    // PC13 output
    GPIOC_CRH &= ~(0xFU << 20);
    GPIOC_CRH |=  (0x2U << 20);

    while (1) {{
        GPIOC_ODR &= ~(1U << 13);  // LED on
        delay(500000);
        GPIOC_ODR |=  (1U << 13);  // LED off
        delay(500000);
    }}
}}
"""


def cmd_stm32_bare_init(name: str):
    proj = SKETCHES / f"{name}_stm32_bare"
    proj.mkdir(parents=True, exist_ok=True)
    (proj / "main.c").write_text(stm32_bare_template(name))
    makefile = f"""CC=arm-none-eabi-gcc
OBJCOPY=arm-none-eabi-objcopy
CFLAGS=-mcpu=cortex-m3 -mthumb -Os -ffunction-sections -fdata-sections -I.
LDFLAGS=-T{LIBS / 'stm32' / 'stm32f103c8t6.ld'} -nostartfiles -Wl,--gc-sections

all: firmware.hex

main.o: main.c
\t$(CC) $(CFLAGS) -c -o $@ $<

firmware.elf: main.o
\t$(CC) $(CFLAGS) -o $@ main.o $(LDFLAGS)

firmware.hex: firmware.elf
\t$(OBJCOPY) -O ihex $< $@

clean:
\trm -f *.o firmware.elf firmware.hex
"""
    (proj / "Makefile").write_text(makefile)
    cprint(f"Created bare-metal STM32 project at {proj}", "green")


def cmd_stm32_bare_build(name: str):
    proj = SKETCHES / f"{name}_stm32_bare"
    if not proj.exists():
        raise SystemExit(f"Project not found: {proj}")
    cprint(f"Building bare-metal STM32 project in {proj} ...", "magenta")
    r = run(["make"], cwd=proj, capture=True)
    if not r or r.returncode != 0:
        print(r.stdout)
        print_error_excerpt(r.stderr if r else "")
        show_compile_result(False, "stm32-bare", name, None, load_config())
        return
    hex_path = proj / "firmware.hex"
    if hex_path.exists():
        # copy to HEX root with name
        dst = HEX / f"{name}-stm32-bare.hex"
        shutil.copy2(hex_path, dst)
        show_compile_result(True, "stm32-bare", name, dst, load_config())
    else:
        show_compile_result(False, "stm32-bare", name, None, load_config())


# ---------- STM32 Mikey Core (Arduino-like) ----------
def stm32_mikey_sketch_template() -> str:
    return """#include "mikey_core.h"

// Arduino-style STM32 example: PC13 LED blink

void setup(void) {
    pinMode(PC13, OUTPUT);
}

void loop(void) {
    digitalWrite(PC13, HIGH);
    delay(300);
    digitalWrite(PC13, LOW);
    delay(300);
}
"""


def cmd_stm32_mikey_init(name: str):
    proj = SKETCHES / f"{name}_stm32_mikey"
    proj.mkdir(parents=True, exist_ok=True)
    (proj / "sketch.c").write_text(stm32_mikey_sketch_template())
    # Simple Makefile using mikey_core + mikey_main + sketch.c
    makefile = f"""CC=arm-none-eabi-gcc
OBJCOPY=arm-none-eabi-objcopy
CFLAGS=-mcpu=cortex-m3 -mthumb -Os -ffunction-sections -fdata-sections -I. -I{LIBS/'stm32'}
LDFLAGS=-T{LIBS/'stm32'/'stm32f103c8t6.ld'} -nostartfiles -Wl,--gc-sections

all: firmware.hex

mikey_core.o: {LIBS/'stm32'/'mikey_core.c'} {LIBS/'stm32'/'mikey_core.h'}
\t$(CC) $(CFLAGS) -c $< -o $@

mikey_main.o: {LIBS/'stm32'/'mikey_main.c'} {LIBS/'stm32'/'mikey_core.h'}
\t$(CC) $(CFLAGS) -c $< -o $@

sketch.o: sketch.c {LIBS/'stm32'/'mikey_core.h'}
\t$(CC) $(CFLAGS) -c $< -o $@

firmware.elf: mikey_core.o mikey_main.o sketch.o
\t$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

firmware.hex: firmware.elf
\t$(OBJCOPY) -O ihex $< $@

clean:
\trm -f *.o firmware.elf firmware.hex
"""
    (proj / "Makefile").write_text(makefile)
    cprint(f"Created Mikey STM32 Core project at {proj}", "green")
    cprint(f"Edit: {proj/'sketch.c'}", "cyan")


def cmd_stm32_mikey_build(name: str):
    proj = SKETCHES / f"{name}_stm32_mikey"
    if not proj.exists():
        raise SystemExit(f"Project not found: {proj}")
    cprint(f"Build #{load_config().get('build_count',0)+1} → Mikey STM32 Core ({name})", "magenta")
    r = run(["make"], cwd=proj, capture=True)
    if not r or r.returncode != 0:
        print(r.stdout)
        print_error_excerpt(r.stderr if r else "")
        show_compile_result(False, "stm32-mikey", name, None, load_config())
        return
    hex_path = proj / "firmware.hex"
    if hex_path.exists():
        dst = HEX / f"{name}-stm32-mikey.hex"
        shutil.copy2(hex_path, dst)
        show_compile_result(True, "stm32-mikey", name, dst, load_config())
    else:
        show_compile_result(False, "stm32-mikey", name, None, load_config())


# ---------- ZIP library installer ----------
def cmd_libs():
    ensure_dirs()
    arduino_lib_dir = LIBS / "arduino"
    arduino_lib_dir.mkdir(parents=True, exist_ok=True)
    if USE_RICH:
        table = Table(title="Installed Arduino libraries (mikey:hexoid)")
        table.add_column("Library")
        for p in sorted(arduino_lib_dir.iterdir()):
            if p.is_dir():
                table.add_row(p.name)
        console.print(table)
    else:
        print("Installed Arduino libraries under", arduino_lib_dir)
        for p in sorted(arduino_lib_dir.iterdir()):
            if p.is_dir():
                print(" -", p.name)


def cmd_lib_add_zip():
    ensure_dirs()
    if USE_RICH:
        console.print(Panel("ZIP Library Installer\nInstall external Arduino/STM32 libraries from ZIP files.",
                            title="ZIP Library Installer"))
    path = input("Enter folder path that contains ZIP files (e.g. /sdcard/Download): ").strip()
    # strip surrounding quotes if user typed "..."
    if (path.startswith("'") and path.endswith("'")) or (path.startswith('"') and path.endswith('"')):
        path = path[1:-1]
    folder = Path(path)
    if not folder.is_dir():
        print(f"'{folder}' is not a directory.")
        return

    zips = sorted(folder.glob("*.zip"))
    if not zips:
        print("No .zip files found in", folder)
        return

    print("Found ZIP files:")
    for i, z in enumerate(zips, start=1):
        print(f"  {i}) {z.name}")
    sel = input("Select ZIP number to install: ").strip()
    try:
        idx = int(sel) - 1
    except ValueError:
        print("Invalid selection.")
        return
    if not (0 <= idx < len(zips)):
        print("Out of range.")
        return
    chosen = zips[idx]
    target_dir = LIBS / "arduino"
    target_dir.mkdir(parents=True, exist_ok=True)
    print(f"Extracting {chosen} ...")
    import zipfile
    with zipfile.ZipFile(chosen, "r") as zf:
        # determine lib folder name
        top_names = [n.split("/")[0] for n in zf.namelist() if "/" in n]
        top = top_names[0] if top_names else chosen.stem
        lib_dir = target_dir / top
        if lib_dir.exists():
            # simple duplicate control: remove old, replace with new
            shutil.rmtree(lib_dir)
        zf.extractall(target_dir)
    print(f"[✔] Installed library into {target_dir}")


# ---------- config / stats / boards ----------
def cmd_config():
    cfg = load_config()
    print(json.dumps(cfg, indent=2))


def cmd_config_hex_dir(argv):
    if len(argv) < 3:
        raise SystemExit("Usage: mhex config-hex-dir <path>")
    path = argv[2]
    cfg = load_config()
    cfg["external_hex_dir"] = path
    save_config(cfg)
    cprint(f"Updated external_hex_dir to: {path}", "green")


def cmd_boards():
    cfg = load_config()
    presets = cfg.get("presets", {})
    if USE_RICH:
        table = Table(title="mikey:hexoid board presets")
        table.add_column("Name")
        table.add_column("Type")
        table.add_column("Details")
        for name, p in presets.items():
            if p["type"] == "avr":
                table.add_row(name, "AVR", p.get("fqbn", ""))
            else:
                table.add_row(name, "STM32", f"{p.get('backend', '')} {p.get('mcu', '')}")
        console.print(table)
    else:
        print("Board presets:")
        for name, p in presets.items():
            print("-", name, "=>", p)


def cmd_stats():
    cfg = load_config()
    bc = cfg.get("build_count", 0)
    last = cfg.get("last_build_time")
    last_dt = datetime.fromtimestamp(last).isoformat() if last else "N/A"
    print(f"Build count: {bc}")
    print(f"Last build kind: {cfg.get('last_build_kind')}")
    print(f"Last build success: {cfg.get('last_build_success')}")
    print(f"Last build time: {last_dt}")


# ---------- conversion ----------
def cmd_convert_arduino_to_stm32(argv):
    if len(argv) < 4:
        raise SystemExit("Usage: mhex convert-arduino-to-stm32 <arduino_name> <stm32_name>")
    ard_name = argv[2]
    stm_name = argv[3]
    ard_dir = SKETCHES / ard_name
    if not ard_dir.exists():
        raise SystemExit(f"Arduino sketch not found: {ard_dir}")
    ino_files = list(ard_dir.glob("*.ino"))
    if not ino_files:
        raise SystemExit(f"No .ino file found for {ard_name}")
    ino = ino_files[0].read_text()

    # naive converter: wrap setup/loop as-is, just include mikey_core.h
    stm_proj = SKETCHES / f"{stm_name}_stm32_mikey"
    stm_proj.mkdir(parents=True, exist_ok=True)
    sketch_c = stm_proj / "sketch.c"
    sketch_c.write_text(
        '#include "mikey_core.h"\n\n'
        "// Auto-converted from Arduino sketch\n\n" +
        ino.replace("void setup()", "void setup(void)").replace("void loop()", "void loop(void)")
    )

    # write Makefile as usual
    cmd_stm32_mikey_init(stm_name)  # rewrites Makefile & default sketch
    # but keep our converted sketch
    sketch_c.write_text(
        '#include "mikey_core.h"\n\n'
        "// Auto-converted from Arduino sketch\n\n" +
        ino.replace("void setup()", "void setup(void)").replace("void loop()", "void loop(void)")
    )

    cprint(f"Converted Arduino sketch '{ard_name}' to STM32 Mikey project '{stm_name}'.", "green")
    cprint(f"STM32 source: {sketch_c}", "cyan")

    # auto-build
    cmd_stm32_mikey_build(stm_name)


def cmd_convert_stm32_to_arduino(argv):
    if len(argv) < 4:
        raise SystemExit("Usage: mhex convert-stm32-to-arduino <stm32_name> <arduino_name>")
    stm_name = argv[2]
    ard_name = argv[3]
    stm_proj = SKETCHES / f"{stm_name}_stm32_mikey"
    sketch_c = stm_proj / "sketch.c"
    if not sketch_c.exists():
        raise SystemExit(f"STM32 Mikey sketch not found: {sketch_c}")
    code = sketch_c.read_text()

    # strip mikey_core.h
    code = code.replace('#include "mikey_core.h"', "#include <Arduino.h>")

    ard_dir = SKETCHES / ard_name
    ard_dir.mkdir(parents=True, exist_ok=True)
    ino = ard_dir / f"{ard_name}.ino"
    ino.write_text("// Auto-converted from STM32 Mikey project\n\n" + code)

    cprint(f"Converted STM32 Mikey project '{stm_name}' to Arduino sketch '{ard_name}'.", "green")
    cprint(f"Arduino source: {ino}", "cyan")

    # test build for Uno
    log = LOGS / f"convert-stm32-to-arduino-{stm_name}-to-{ard_name}.log"
    cmd = [
        str(ARD_CLI),
        "--config-file", str(CLI_CFG),
        "compile",
        "--fqbn", "arduino:avr:uno",
        "--output-dir", str(HEX / ard_name),
        str(ard_dir),
    ]
    r = run(cmd, capture=True, log_file=str(log))
    if not r or r.returncode != 0:
        cprint("Conversion done, but Arduino build had errors.", "yellow")
        cprint(f"Check code: {ino}", "cyan")
        cprint(f"Error log: {log}", "cyan")
        print_error_excerpt(r.stderr if r else "")
    else:
        cprint("[✔] Test build for Uno OK.", "green")


# ---------- main ----------
def main(argv):
    ensure_dirs()
    if len(argv) < 2:
        cmd_help()
        return 0
    cmd = argv[1]

    if cmd == "doctor":
        cmd_doctor()
    elif cmd == "help":
        cmd_help()
    elif cmd == "new":
        if len(argv) < 3:
            raise SystemExit("Usage: mhex new <name>")
        cmd_new(argv[2])
    elif cmd == "compile":
        cmd_compile(argv)
    elif cmd == "stm32-bare-init":
        if len(argv) < 3:
            raise SystemExit("Usage: mhex stm32-bare-init <name>")
        cmd_stm32_bare_init(argv[2])
    elif cmd == "stm32-bare-build":
        if len(argv) < 3:
            raise SystemExit("Usage: mhex stm32-bare-build <name>")
        cmd_stm32_bare_build(argv[2])
    elif cmd == "stm32-mikey-init":
        if len(argv) < 3:
            raise SystemExit("Usage: mhex stm32-mikey-init <name>")
        cmd_stm32_mikey_init(argv[2])
    elif cmd == "stm32-mikey-build":
        if len(argv) < 3:
            raise SystemExit("Usage: mhex stm32-mikey-build <name>")
        cmd_stm32_mikey_build(argv[2])
    elif cmd == "libs":
        cmd_libs()
    elif cmd == "lib-add-zip":
        cmd_lib_add_zip()
    elif cmd == "config":
        cmd_config()
    elif cmd == "config-hex-dir":
        cmd_config_hex_dir(argv)
    elif cmd == "boards":
        cmd_boards()
    elif cmd == "stats":
        cmd_stats()
    elif cmd == "convert-arduino-to-stm32":
        cmd_convert_arduino_to_stm32(argv)
    elif cmd == "convert-stm32-to-arduino":
        cmd_convert_stm32_to_arduino(argv)
    else:
        cmd_help()
        cprint(f"Unknown command '{cmd}'", "red")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
EOF

chmod +x "$MHEX_PY"

# ---------- launcher ----------
MHEX_LAUNCHER="$BIN/mhex"
cat >"$MHEX_LAUNCHER" <<EOF
#!/usr/bin/env bash
export MIKEY_HEXOID_BASE="$BASE"
export PATH="$BIN:\$PATH"
exec "$VENV/bin/python3" "$MHEX_PY" "\$@"
EOF
chmod +x "$MHEX_LAUNCHER"

# ---------- PATH hookup ----------
SHELL_RC="$HOME/.bashrc"
if ! grep -q 'mikey-hexoid/bin' "$SHELL_RC" 2>/dev/null; then
  echo 'export PATH="$HOME/mikey-hexoid/bin:$PATH"' >>"$SHELL_RC"
  ok "Added mikey-hexoid/bin to PATH in $SHELL_RC"
else
  ok "PATH entry for mikey-hexoid already present in $SHELL_RC"
fi

echo
echo "=============================================="
echo " mikey:hexoid v4.0.0 installation complete!"
echo
echo "Open a NEW shell or run:"
echo "  source ~/.bashrc"
echo
echo "Then test:"
echo "  mhex doctor"
echo "  mhex new blink"
echo "  mhex compile blink --preset uno"
echo
echo "STM32 bare-metal:"
echo "  mhex stm32-bare-init f103test"
echo "  mhex stm32-bare-build f103test"
echo
echo "Mikey STM32 Core (Arduino-like, MCU pins):"
echo "  mhex stm32-mikey-init bluepill2"
echo "  mhex stm32-mikey-build bluepill2"
echo
echo "ZIP libraries:"
echo "  mhex lib-add-zip"
echo "  mhex libs"
echo "=============================================="
