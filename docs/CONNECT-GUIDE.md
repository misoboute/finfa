# How to connect to FINFA

This package gives you one **config line** (it starts with `vless://`). You paste
that line into a free app, press connect, and you're on the open internet.

Your config line is at the bottom of this document, under **YOUR CONFIG**.

---

## Android

1. Install **v2rayNG** — from Google Play, or from the **one official repo**:
   **github.com/2dust/v2rayNG** (author **2dust**; ignore look-alikes). From
   **Releases → latest**, choose the `arm64-v8a` APK. Use a **recent** version —
   builds older than 2023 predate this protocol and will not connect.
2. Copy the whole `vless://...` line from the bottom of this document.
3. Open v2rayNG → tap the **+** (top right) → **Import config from clipboard**.
4. The profile appears in the list. Tap it once to select it.
5. Tap the round **▶ (play)** button at the bottom right to connect.
6. Allow the VPN permission if Android asks.

To check it works: open a browser to `https://api.ipify.org` — it should show the
server's IP, not yours.

---

## iPhone / iPad

The simplest free app is **V2Box** (App Store). **Streisand** and **Hiddify** also
work if V2Box isn't available in your region's App Store.

1. Install **V2Box - V2ray Client**.
2. Copy the whole `vless://...` line from the bottom of this document.
3. Open V2Box → **Configs** tab → tap **+** (top right) → **Import from clipboard**.
4. Tap the imported config to select it (a tick appears).
5. Go to the **Home** tab → tap **Connect** → allow the VPN permission.

If V2Box isn't installable: install **Streisand**, tap **+** → **Add from clipboard**,
then connect — the steps are the same idea.

---

## Windows

Use **v2rayN** (it bundles the Xray engine and supports this config out of the box).

1. Download **v2rayN** from the **one official repo** — **github.com/2dust/v2rayN**
   (author is **2dust**; ignore the many look-alike/fork repos). Open
   **Releases → latest** (https://github.com/2dust/v2rayN/releases/latest) and
   download **`v2rayN-windows-64.zip`** — it bundles the Xray engine and .NET, so
   there's nothing else to install. Unzip anywhere, run `v2rayN.exe`.
   (If Windows SmartScreen warns, choose "More info" → "Run anyway".)
   Use a **recent** version — builds older than 2023 predate this protocol and
   will not connect.
2. Copy the whole `vless://...` line from the bottom of this document.
3. In v2rayN, press **Ctrl+V** (or top menu **Servers → Import from clipboard**).
4. The server appears in the list. Click it to select.
5. Bottom-right tray icon → right-click **v2rayN** → **System Proxy → Set system proxy**.
6. Right-click again → make sure mode is **Set system proxy**. You're connected.

To turn it off: right-click the tray icon → **System Proxy → Clear system proxy**.

---

## macOS

Use **V2Box** (Mac App Store) or **Hiddify** (official site / GitHub).

1. Install **V2Box** from the App Store.
2. Copy the whole `vless://...` line from the bottom of this document.
3. Open V2Box → **Configs** → **+** → **Import from clipboard** → select it.
4. **Home** → **Connect** → allow the VPN permission.

---

## Linux

Use **Hiddify** (AppImage from its official releases) or **nekoray**.

1. Download the **Hiddify** AppImage, make it executable, run it.
2. Copy the `vless://...` line → in Hiddify: **+** (Add) → **Add from clipboard**.
3. Select the profile → press the big connect button.

---

## If it doesn't connect

- **Make sure your device's clock is correct** (set date & time to *automatic*).
  This protocol fails if the clock is off by more than a couple of minutes.
- Toggle the connection off and on once.
- Switch between Wi-Fi and mobile data and try again.
- If you have several apps installed, make sure only one VPN is active at a time.
- Keep this config private — it's tied to your account. Don't share it; if more
  than a few devices use it at once, the account is temporarily paused.

---

## YOUR CONFIG

Copy this entire line:

```
{{CONFIG_LINK}}
```
