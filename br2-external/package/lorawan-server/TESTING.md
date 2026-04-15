# LoRaWAN Server UDP Testing

This server does not speak plain text over `telnet`. It listens on UDP, default port `1680`, and expects Semtech packet-forwarder frames.

Use this document to verify:

1. `PULL_DATA` / `PULL_ACK`
2. join uplink -> `PUSH_ACK` -> `PULL_RESP`
3. normal uplink with MAC commands -> `PUSH_ACK` -> `PULL_RESP`

## What Must Exist In The DB

The UDP listener only emits LoRaWAN downlinks when matching state exists in SQLite:

- a `network`
- a `gateway`
- either a `device` for join requests
- or a `node` for normal uplinks

This seed data matches the values used in the UDP tests in `src/udp/udp.zig`.

```bash
sqlite3 /tmp/lorawan.db <<'SQL'
INSERT INTO networks(name, network_json) VALUES
('public','{"netid":"000013","tx_codr":"4/5","join1_delay":5,"rx1_delay":1,"gw_power":14,"rxwin_init":{"rx1_dr_offset":0,"rx2_data_rate":0,"frequency":869.525}}');

INSERT INTO gateways(mac, name, network_name, gateway_json) VALUES
('0102030405060708','gateway-a','public','{"tx_rfch":0}');

INSERT INTO devices(name, dev_eui, app_eui, app_key, device_json) VALUES
('node-a','1112131415161718','0102030405060708','2b7e151628aed2a6abf7158809cf4f3c','{"network_name":"public","dev_addr":"26011bda"}');

INSERT INTO nodes(dev_addr, device_id, node_json) VALUES
('01020304',NULL,'{"appskey":"101112131415161718191a1b1c1d1e1f","nwkskey":"202122232425262728292a2b2c2d2e2f","fcntup":null,"fcntdown":0,"rxwin_use":{"rx1_dr_offset":0,"rx2_data_rate":0,"frequency":869.525},"adr_tx_power":0,"adr_data_rate":0,"last_battery":null,"last_margin":null,"pending_mac_commands":null}');
SQL
```

If you rerun the seed, remove the DB first:

```bash
rm -f /tmp/lorawan.db
```

## Run The Server

```bash
cd /home/vnareiko/Homespace/bumblebee/br2-external/package/lorawan-server/src
LORAWAN_SERVER_DB_PATH=/tmp/lorawan.db zig build run
```

Defaults:

- UDP: `0.0.0.0:1680`
- HTTP: `0.0.0.0:8080`

## Script 1: Join Smoke Test

This verifies:

- gateway can register a pull target with `PULL_DATA`
- join uplink gets `PUSH_ACK`
- server emits a `PULL_RESP` join-accept downlink
- server creates a node row and join event

Requirements:

```bash
python3 -m pip install pycryptodome
```

Run:

```bash
python3 - <<'PY'
import socket, json, base64
from Crypto.Hash import CMAC
from Crypto.Cipher import AES

HOST = "127.0.0.1"
PORT = 1680
GW = bytes([1, 2, 3, 4, 5, 6, 7, 8])
APP_EUI = bytes.fromhex("0102030405060708")
DEV_EUI = bytes.fromhex("1112131415161718")
DEV_NONCE = bytes([0xAA, 0xBB])
APP_KEY = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")

def cmac(key, msg):
    c = CMAC.new(key, ciphermod=AES)
    c.update(msg)
    return c.digest()

def join_request():
    mhdr = b"\x00"
    payload = mhdr + APP_EUI[::-1] + DEV_EUI[::-1] + DEV_NONCE
    mic = cmac(APP_KEY, payload)[:4]
    return payload + mic

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 1700))
sock.settimeout(2)

pull = b"\x01\x00\x01\x02" + GW
sock.sendto(pull, (HOST, PORT))
print("sent PULL_DATA")
print("pull_ack:", sock.recvfrom(2048)[0].hex())

phy = join_request()
rxpk = {
    "rxpk": [{
        "modu": "LORA",
        "freq": 868.10,
        "datr": "SF12BW125",
        "codr": "4/5",
        "data": base64.b64encode(phy).decode(),
        "tmst": 42
    }]
}
push = b"\x01\x12\x00\x00" + GW + json.dumps(rxpk, separators=(",", ":")).encode()
sock.sendto(push, (HOST, PORT))
print("sent PUSH_DATA(join)")
print("push_ack:", sock.recvfrom(2048)[0].hex())
resp = sock.recvfrom(4096)[0]
print("pull_resp_ident:", resp[3])
print("pull_resp_json:", resp[4:].decode())
PY
```

Expected:

- `pull_ack` is `01000104`
- `push_ack` is `01120001`
- `pull_resp_ident` is `3`
- JSON contains `txpk`

Verify persisted state:

```bash
sqlite3 /tmp/lorawan.db "select event_type, payload_json from events order by id desc limit 5;"
sqlite3 /tmp/lorawan.db "select dev_addr, device_id, node_json from nodes;"
```

## Script 2: Uplink With MAC Response

This verifies:

- `PULL_DATA` / `PULL_ACK`
- normal uplink gets `PUSH_ACK`
- server recognizes MAC commands in `FOpts`
- server emits a downlink in `PULL_RESP`

This script sends a `DevStatusAns` in uplink `FOpts`. The server should answer with MAC commands in a downlink frame.

```bash
python3 - <<'PY'
import socket, json, base64, struct
from Crypto.Hash import CMAC
from Crypto.Cipher import AES

HOST = "127.0.0.1"
PORT = 1680
GW = bytes([1, 2, 3, 4, 5, 6, 7, 8])
DEV_ADDR = bytes.fromhex("01020304")
NWK_S_KEY = bytes.fromhex("202122232425262728292a2b2c2d2e2f")

def cmac(key, msg):
    c = CMAC.new(key, ciphermod=AES)
    c.update(msg)
    return c.digest()

def build_uplink(dev_addr_be, nwk_s_key, fcnt, fopts):
    mhdr = b"\x40"
    dev_addr_le = dev_addr_be[::-1]
    fctrl = bytes([len(fopts)])
    fcnt_le = struct.pack("<H", fcnt & 0xFFFF)
    msg = mhdr + dev_addr_le + fctrl + fcnt_le + fopts

    b0 = bytearray(16)
    b0[0] = 0x49
    b0[6:10] = dev_addr_le
    b0[10:14] = struct.pack("<I", fcnt)
    b0[15] = len(msg)
    mic = cmac(nwk_s_key, bytes(b0) + msg)[:4]
    return msg + mic

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 1701))
sock.settimeout(2)

pull = b"\x01\x00\x02\x02" + GW
sock.sendto(pull, (HOST, PORT))
print("sent PULL_DATA")
print("pull_ack:", sock.recvfrom(2048)[0].hex())

# DevStatusAns: CID=0x06, battery=100, margin=5
fopts = bytes([0x06, 100, 5])
phy = build_uplink(DEV_ADDR, NWK_S_KEY, 1, fopts)
rxpk = {
    "rxpk": [{
        "modu": "LORA",
        "freq": 868.10,
        "datr": "SF12BW125",
        "codr": "4/5",
        "data": base64.b64encode(phy).decode(),
        "tmst": 77
    }]
}
push = b"\x01\x33\x33\x00" + GW + json.dumps(rxpk, separators=(",", ":")).encode()
sock.sendto(push, (HOST, PORT))
print("sent PUSH_DATA(uplink)")
print("push_ack:", sock.recvfrom(2048)[0].hex())
resp = sock.recvfrom(4096)[0]
print("pull_resp_ident:", resp[3])
print("pull_resp_json:", resp[4:].decode())
PY
```

Expected:

- `pull_ack` is `01000204`
- `push_ack` is `01333301`
- `pull_resp_ident` is `3`
- JSON contains `txpk`

Check resulting events:

```bash
sqlite3 /tmp/lorawan.db "select event_type, payload_json from events order by id desc limit 10;"
```

## Useful Checks

Health endpoint:

```bash
curl -i http://127.0.0.1:8080/healthz
```

Run the built-in tests directly:

```bash
cd /home/vnareiko/Homespace/bumblebee/br2-external/package/lorawan-server/src
zig build test --test-filter "join requests load registered devices from storage and create a node"
zig build test --test-filter "tx ack persists pending mac commands and later uplink syncs node state"
```
