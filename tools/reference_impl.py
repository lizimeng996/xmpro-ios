#!/usr/bin/env python3
"""Independent Python reference implementation of the XMPro (lite-client)
protocol cryptography, written directly from the Kotlin sources of
angusdevgo/XMPro (AGPL-3.0-or-later):

  android/app/src/main/kotlin/teikengstudio/xmpro/api/XmlyCrypto.kt
  android/app/src/main/kotlin/teikengstudio/xmpro/api/XmlyHistory.kt
  android/app/src/main/kotlin/teikengstudio/xmpro/api/XmlyLogin.kt
  android/app/src/main/kotlin/teikengstudio/xmpro/api/XmlyRewards.kt

Protocol constants are *parsed out of the Kotlin source files at runtime*
so no constant value is duplicated by hand in this project. The script:

  1. verifies itself against the golden vectors in XmlyCryptoTest.kt;
  2. emits tools/golden_vectors.json with deterministic input/output pairs
     that the Swift unit tests must reproduce byte-for-byte.

Usage:
  reference_impl.py [path-to-XMPro-android-src]
"""

import base64
import hashlib
import json
import re
import sys
from pathlib import Path

from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad

SRC = Path(sys.argv[1] if len(sys.argv) > 1 else
           Path.home() / "workspace/xmpro-reference/XMPro/android/app/src")
MAIN = SRC / "main/kotlin/teikengstudio/xmpro"
TEST = SRC / "test/kotlin/teikengstudio/xmpro"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


crypto_kt = read(MAIN / "api/XmlyCrypto.kt")
history_kt = read(MAIN / "api/XmlyHistory.kt")
login_kt = read(MAIN / "api/XmlyLogin.kt")
rewards_kt = read(MAIN / "api/XmlyRewards.kt")


def grab(text: str, pattern: str) -> str:
    m = re.search(pattern, text)
    assert m, f"pattern not found: {pattern}"
    return m.group(1)


# ---- constants parsed from source (mechanism inputs, never printed) ----
PLAY_KEY = bytes.fromhex(grab(crypto_kt, r'playKeyBytes = hex\("([0-9a-f]+)"\)'))
DURATION_KEY = grab(crypto_kt, r'durationKeyBytes = "([^"]+)"').encode("ascii")
TICKET_MATERIAL = bytes.fromhex(
    grab(crypto_kt, r'ticketMaterial = hex\("([0-9a-f]+)"\)'))
ACTIVITY_MATERIAL = grab(crypto_kt, r'ACTIVITY_MATERIAL = "([^"]+)"')
HISTORY_MATERIAL = grab(history_kt, r'MATERIAL = "([^"]+)"')
LOGIN_SALT = grab(login_kt, r'SALT =\s*\n?\s*"([^"]+)"')
REWARD_SALT = grab(rewards_kt, r'SALT = "([^"]+)"')


# ---- AES/ECB/PKCS5 envelope (XmlyCrypto.encrypt/decrypt) ----
def envelope_encrypt(json_text: str, key: bytes) -> str:
    raw = json_text.encode("utf-8")
    ct = AES.new(key, AES.MODE_ECB).encrypt(pad(raw, 16))
    b64 = base64.urlsafe_b64encode(ct).decode("ascii").rstrip("=")
    wrapped = "\n".join(b64[i:i + 76] for i in range(0, len(b64), 76))
    return wrapped + "\n"


def envelope_decrypt(value: str, key: bytes) -> str:
    text = value.replace("\r", "").replace("\n", "")
    text = text.replace("-", "+").replace("_", "/")
    text += "=" * ((4 - len(text) % 4) % 4)
    raw = base64.b64decode(text)
    assert raw and len(raw) % 16 == 0
    return unpad(AES.new(key, AES.MODE_ECB).decrypt(raw), 16).decode("utf-8")


def _lower_ascii(data: bytes) -> bytes:
    return bytes(b + 32 if 65 <= b <= 90 else b for b in data)


def md5_sign(params: dict, material: str) -> str:
    """Shared shape of activitySignature / history signature."""
    canonical = "".join(f"{k}={params[k]}&" for k in sorted(params)) + material
    return hashlib.md5(_lower_ascii(canonical.encode("utf-8"))).hexdigest()


def activity_signature(params: dict) -> str:
    return md5_sign(params, ACTIVITY_MATERIAL)


def history_signature(params: dict) -> str:
    return md5_sign(params, HISTORY_MATERIAL)


def login_signature(values: dict) -> str:
    canonical = "".join(f"{k}={values[k]}&" for k in sorted(values)).upper()
    return hashlib.sha1((canonical + LOGIN_SALT).encode("utf-8")).hexdigest()


def reward_signature(request_id: str, uid: str, timestamp: int,
                     second_phase=None) -> str:
    parts = f"{request_id}&{uid}&{timestamp}"
    if second_phase is not None:
        parts += f"&{second_phase}"
    return hashlib.md5(f"{parts}&{REWARD_SALT}".encode("utf-8")).hexdigest()


def fresh_ticket(uid: str, device_id: str, attributes, now_seconds: int,
                 uuid_bytes: bytes) -> str:
    """TAC ticket with injected randomness/time so it is reproducible."""
    identity = hashlib.md5(f"{uid}|{device_id}".encode("utf-8")).digest()
    uuid = bytearray(uuid_bytes)
    uuid[6] = (uuid[6] & 0x0F) | 0x40
    uuid[8] = (uuid[8] & 0x3F) | 0x80
    payload = bytearray(36)
    payload[0] = (now_seconds >> 24) & 0xFF
    payload[1] = (now_seconds >> 16) & 0xFF
    payload[2] = (now_seconds >> 8) & 0xFF
    payload[3] = now_seconds & 0xFF
    payload[4:20] = identity
    for i in range(16):
        payload[20 + i] = uuid[i] ^ identity[i]
    suffix = ("com.ximalaya.ting.lite!1.3.24!3.4.10.3!" +
              (attributes if attributes is not None else
               f"b=lite&s=lite_track_play_url&&u={uid}")).encode("utf-8")
    digest = hashlib.sha256(bytes(payload) + b"TAC" + TICKET_MATERIAL + suffix).digest()
    body = bytes(payload) + digest + suffix
    return "TAC" + base64.urlsafe_b64encode(body).decode("ascii").rstrip("=")


def main() -> None:
    vectors = {}

    # 1. Verify against the golden vectors in XmlyCryptoTest.kt
    assert activity_signature({"a": "b", "z": "Z"}) == \
        "a6fec7af506479d08f411bf040d8c762"
    assert activity_signature({"uid": "123", "count": "2"}) == \
        "4a8f64e65478ecc6c823c708bb70c9b0"
    print("activity_signature: matches both Kotlin golden vectors")

    # 2. AES envelope vectors (deterministic)
    json1 = '{"trackId":123456,"bitRate":64000,"duration":301}'
    env1 = envelope_encrypt(json1, PLAY_KEY)
    assert envelope_decrypt(env1, PLAY_KEY) == json1
    vectors["envelope_play"] = {"json": json1, "envelope": env1}
    json2 = '{"title":"第一集","ok":true}'
    env2 = envelope_encrypt(json2, DURATION_KEY)
    assert envelope_decrypt(env2.replace("\n", ""), DURATION_KEY) == json2
    vectors["envelope_duration"] = {"json": json2, "envelope": env2}
    print("envelope encrypt/decrypt: round-trip OK, vectors recorded")

    # 3. Activity-config style signature (the real call shape: uid excluded
    #    from the body but included in the signature params)
    vectors["activity_signature_samples"] = [
        {"params": {"deviceId": "android-0123456789abcdef",
                    "timestamp": "1700000000000", "uid": "123456"},
         "signature": activity_signature(
             {"deviceId": "android-0123456789abcdef",
              "timestamp": "1700000000000", "uid": "123456"})},
        {"params": {"deviceId": "android-0123456789abcdef",
                    "timestamp": "1700000000000", "uid": "123456",
                    "duration": "1800"},
         "signature": activity_signature(
             {"deviceId": "android-0123456789abcdef",
              "timestamp": "1700000000000", "uid": "123456",
              "duration": "1800"})},
    ]

    # 4. History signature sample (merge params + context shape)
    hist_params = {
        "mergeRecords": '[{"endedAt":"1700000060000","startedAt":"1700000000000",'
                        '"type":"1","itemId":"44131624","childId":"77112233",'
                        '"breakSecond":"120","direction":0}]',
        "uid": "123456", "token": "abcdef0123456789", "device": "android",
        "deviceId": "android-0123456789abcdef", "version": "3.4.10",
        "channel": "and-f5", "impl": "com.ximalaya.ting.lite",
    }
    # NOTE: in XmlyHistory the "direction" value enters the signature via its
    # string form; the map is Map<String,String>, so 0 -> "0".
    hist_params_str = dict(hist_params)
    hist_params_str["mergeRecords"] = hist_params["mergeRecords"].replace(
        '"direction":0', '"direction":0')
    vectors["history_signature_sample"] = {
        "params": hist_params_str,
        "signature": history_signature(hist_params_str),
    }

    # 5. Login signature samples
    login_values = {"mobile": "ENCRYPTED_PLACEHOLDER", "sendType": "1",
                    "biz": "1", "nonce": "nonce-sample-1700000000",
                    "fdsOtp": '{"captcha_id":"x"}'}
    vectors["login_signature_sample"] = {
        "values": login_values, "signature": login_signature(login_values)}

    # 6. Reward signature samples
    vectors["reward_signature_samples"] = [
        {"requestId": "11111111-2222-3333-4444-555555555555", "uid": "123456",
         "timestamp": 1700000000000, "secondPhase": None,
         "signature": reward_signature(
             "11111111-2222-3333-4444-555555555555", "123456", 1700000000000)},
        {"requestId": "11111111-2222-3333-4444-555555555555", "uid": "123456",
         "timestamp": 1700000000000, "secondPhase": "true",
         "signature": reward_signature(
             "11111111-2222-3333-4444-555555555555", "123456", 1700000000000,
             "true")},
    ]

    # 7. TAC ticket with fixed randomness (mirrors XmlyCryptoTest inputs)
    fixed_uuid = bytes.fromhex("00112233445566778899aabbccddeeff")
    ticket = fresh_ticket("123456", "android-0123456789abcdef", None,
                          1700000000, fixed_uuid)
    body = base64.urlsafe_b64decode(ticket[3:] + "=" * ((4 - len(ticket[3:]) % 4) % 4))
    suffix = b"com.ximalaya.ting.lite!1.3.24!3.4.10.3!b=lite&s=lite_track_play_url&&u=123456"
    assert len(body) == 4 + 16 + 16 + 32 + len(suffix)
    assert body[-len(suffix):] == suffix
    assert int.from_bytes(body[0:4], "big") == 1700000000
    vectors["ticket_fixed"] = {
        "uid": "123456", "deviceId": "android-0123456789abcdef",
        "attributes": None, "nowSeconds": 1700000000,
        "uuidHex": fixed_uuid.hex(), "ticket": ticket,
    }
    print("ticket: structure verified against Kotlin test expectations")

    out = Path(__file__).with_name("golden_vectors.json")
    out.write_text(json.dumps(vectors, ensure_ascii=False, indent=2),
                   encoding="utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
