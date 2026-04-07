# alt-spacewar

Сборка boot.img + rootfs.img для Nothing Phone (1) (spacewar) с Alt Linux.

## Быстрый старт

```bash
./build_firmware.sh
```

Результат: `out/boot.img` + `out/rootfs.img`

### Прошивка

```bash
adb reboot bootloader
fastboot flash boot out/boot.img
fastboot flash userdata out/rootfs.img
fastboot reboot
```

## Статус загрузки

###  Работает

- **Ядро** — загружается
- **Rootfs** — монтируется, systemd стартует
- **USB UDC** — `a600000.usb` обнаружен ядром
- **DRM/DPU** — драйвер `msm_dpu` загружен, CRTC/planes создаются
- **DSI** — контроллер инициализирован, endpoint подключён к панели
- **Panel** — `panel-visionox-rm692e5` (модуль, загружается через modules-load.d)
- **PCIe** — `pcie-qcom` загружен
- **Wi-Fi** — `ath11k` + firmware доступны
- **Bluetooth** — `btqca` + hciuart QCA
- **Interconnect** — `INTERCONNECT_QCOM_SC7280=y`
- **USB configfs** — NCM, RNDIS, ACM скомпилированы
- **USB role switch** — `CONFIG_USB_ROLE_SWITCH=y`, узел в DTB

###  Частично работает

- **USB gadget** — UDC найден, но role-switch sysfs-узлы пусты. Dwc3-qcom не завершает probe  `phy-qcom-qmp-usb` + `phy-qcom-usb-snps-femto-v2` + rebind dwc3-qcom.
- **DRM/DPU** — `frame done timeout` и `kickoff timeout (-110)`. Панель загружается как модуль (`=m`), DPU начинает инициализацию до её появления. Обход: сервис `reprobe-dpu` делает unbind/bind DPU после загрузки модуля.

### Не работает

- **GPU (Adreno 660)** — `sync_state() pending due to 3d6a000.gmu`. Не может инициализировать GPU, тактирование остаётся заблокированным, что вызывает таймауты DPU.
- **USB PHY** — `CONFIG_PHY_QCOM_QUSB2` и `CONFIG_PHY_QCOM_EUSB2_REPEATER` отключены. Без них USB-контроллер не может переключиться в peripheral mode, gadget не создаётся.


## Известные проблемы

### 1. GPU: `sync_state() pending due to 3d6a000.gmu`

**Симптом:** `gpu_cc-sc7280` и `gcc-sc7280` ждут устройство GMU, которое не существует (нет в ядре).

### 2. DRM: `frame done timeout`, `kickoff timeout -110`

**Симптом:** DPU пытается отрисовать кадр, но GPU не отвечает. Панель загружается слишком поздно.

### 3. USB: role-switch узлы пусты

**Симптом:** `a600000.usb` есть в UDC, но `dr_mode` и `role` sysfs-файлы отсутствуют.


### 4. Phosh: не запускается

**Симптом:** Служба `phosh.service` — inactive (dead), Wayland-сокет отсутствует.

**Причина:** DRM/DPU не в рабочем состоянии → нет DRM-устройств → phoc/phosh не могут стартовать.

**Решение:** Исправить GPU + DRM (пункты 1-2), затем переключить `default.target` на `graphical.target`.

## Зависимости

- `mkbootimg` — упаковка boot.img
- `xz`, `rsync`, `fakeroot` — работа с rootfs
- `udisksctl` — монтирование образов
- `gzip` — сжатие ядра
- `mkfs.ext4` или `mkfs.f2fs` — создание rootfs.img
