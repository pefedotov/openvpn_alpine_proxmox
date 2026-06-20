# Alpine OpenVPN for Proxmox LXC

[English](#english) | [Русский](#русский)

---

## English

### What it is

A set of shell scripts for deploying and managing an OpenVPN server inside an Alpine Linux LXC container on a Proxmox VE host. Designed for quick, reproducible VPN deployment with minimal manual steps.

### Requirements

- **Proxmox VE** with `pct` and `pveam` available
- Root access on the Proxmox host

### Quick start

Run on the Proxmox host:

```bash
curl -sL https://raw.githubusercontent.com/pefedotov/openvpn_alpine_proxmox/main/main.sh | bash
```

Select option **4 (Full installation)** for one-shot setup.

### Scripts

| Script | Location | Purpose |
|---|---|---|
| `main.sh` | Proxmox host | Container creation, Proxmox setup, full deployment |
| `vpn_server.sh` | Inside container | OpenVPN install, config changes, full cleanup |
| `vpn_users.sh` | Inside container | Add/delete/list clients, regenerate .ovpn files |

### Step-by-step setup

1. **Proxmox configuration** — adds cgroup rules for TUN device and enables IP forwarding on the host
2. **Create container** — creates Alpine LXC, installs OpenVPN + easy-rsa + iptables, copies management scripts inside
3. **Enable access in Proxmox** — sets up DNAT and MASQUERADE so external clients can reach the VPN port
4. **Full installation** — runs all steps above plus OpenVPN server configuration inside the container

### Managing the server (inside container)

```bash
# Enter container
pct enter <ID>

# Server management
/root/vpn_server.sh          # interactive menu
/root/vpn_server.sh install  # full install
/root/vpn_server.sh config   # change port, protocol, DNS, etc.
/root/vpn_server.sh cleanup  # remove OpenVPN completely

# User management
/root/vpn_users.sh              # interactive menu
/root/vpn_users.sh add alice    # create client, get .ovpn
/root/vpn_users.sh del alice    # revoke and delete client
/root/vpn_users.sh list         # show all clients
/root/vpn_users.sh ovpn alice   # regenerate .ovpn (e.g. after IP change)
```

### What gets installed

- **OpenVPN** with TCP, AES-256-GCM, SHA512, TLS-Auth
- **easy-rsa** with EC keys and SHA-512 digest
- **iptables** with NAT masquerade for VPN traffic
- Default VPN subnet: `10.8.0.0/24`, port `1194/tcp`

### .ovpn file

Each client gets a self-contained `.ovpn` file with embedded certificates and keys — no extra files needed on the client side. Import it into any OpenVPN client (Windows, macOS, Linux, Android, iOS).

### Cleanup

```bash
/root/vpn_server.sh cleanup
```

Removes OpenVPN, all certificates, client files, iptables rules, and disables IP forwarding.

---

## Русский

### Что это

Набор shell-скриптов для развёртывания и управления сервером OpenVPN внутри LXC-контейнера Alpine Linux на хосте Proxmox VE. Предназначен для быстрого и воспроизводимого развертывания VPN с минимальным количеством ручных действий.

### Требования

- **Proxmox VE** с доступными командами `pct` и `pveam`
- Root-доступ на хосте Proxmox

### Быстрый старт

Выполните на хосте Proxmox:

```bash
curl -sL https://raw.githubusercontent.com/pefedotov/openvpn_alpine_proxmox/main/main.sh | bash
```

Выберите пункт **4 (Полная установка)** для автоматического развёртывания.

### Скрипты

| Скрипт | Расположение | Назначение |
|---|---|---|
| `main.sh` | Хост Proxmox | Создание контейнера, настройка Proxmox, полное развёртывание |
| `vpn_server.sh` | Внутри контейнера | Установка OpenVPN, изменение параметров, полная очистка |
| `vpn_users.sh` | Внутри контейнера | Добавление/удаление/список клиентов, пересоздание .ovpn |

### Пошаговая установка

1. **Настройка Proxmox** — добавляет cgroup-права для устройства TUN и включает IP-форвардинг на хосте
2. **Создание контейнера** — создаёт Alpine LXC, устанавливает OpenVPN + easy-rsa + iptables, копирует скрипты управления внутрь
3. **Включение доступа в Proxmox** — настраивает DNAT и MASQUERADE для доступа внешних клиентов к VPN-порту
4. **Полная установка** — выполняет все предыдущие шаги плюс настройку сервера OpenVPN внутри контейнера

### Управление сервером (внутри контейнера)

```bash
# Вход в контейнер
pct enter <ID>

# Управление сервером
/root/vpn_server.sh          # интерактивное меню
/root/vpn_server.sh install  # полная установка
/root/vpn_server.sh config   # изменение порта, протокола, DNS и т.д.
/root/vpn_server.sh cleanup  # полное удаление OpenVPN

# Управление пользователями
/root/vpn_users.sh              # интерактивное меню
/root/vpn_users.sh add alice    # создание клиента, получение .ovpn
/root/vpn_users.sh del alice    # отзыв и удаление клиента
/root/vpn_users.sh list         # список всех клиентов
/root/vpn_users.sh ovpn alice   # пересоздание .ovpn (например, при смене IP)
```

### Что устанавливается

- **OpenVPN** с TCP, AES-256-GCM, SHA512, TLS-Auth
- **easy-rsa** с EC-ключами и SHA-512
- **iptables** с NAT masquerade для VPN-трафика
- Подсеть VPN по умолчанию: `10.8.0.0/24`, порт `1194/tcp`

### .ovpn файл

Каждый клиент получает автономный `.ovpn` файл с встроенными сертификатами и ключами — на стороне клиента дополнительные файлы не нужны. Импортируйте его в любой OpenVPN-клиент (Windows, macOS, Linux, Android, iOS).

### Очистка

```bash
/root/vpn_server.sh cleanup
```

Удаляет OpenVPN, все сертификаты, клиентские файлы, правила iptables и отключает IP-форвардинг.
