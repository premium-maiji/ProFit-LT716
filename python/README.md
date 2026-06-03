# FitPro Python Tools

`fitpro_notify.py` is the Python BLE CLI used to scan, initialize, send FitPro
notification packets, and optionally clean up a stuck macOS Bluetooth
connection.

`helpers/` contains small macOS-only Swift helper tools called by optional
cleanup flags. They are not part of the iOS app.

Install dependencies with:

```sh
python3 -m pip install -r python/requirements.txt
```

The Python state file is generated next to the CLI and is intentionally ignored
because it can contain watch Bluetooth identifiers:

```sh
python/.fitpro_notify_state.json
```

Example:

```sh
python3 python/fitpro_notify.py --help
```

Common examples:

```sh
python3 python/fitpro_notify.py --scan --all
python3 python/fitpro_notify.py --auto-send --target-name LT716 --app sms --text "HELLO"
```
