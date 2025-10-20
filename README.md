# Demo Trading for Zerodha

A single-file Flutter demo app that replicates a simple trading UI (Watchlist, Orders, Portfolio) and fetches real market quotes using the **Alpha Vantage** `GLOBAL_QUOTE` endpoint. This repo is intended as a starter/demo — it uses Alpha Vantage polling with a conservative interval to respect free-tier rate limits.

> **Note:** The complete `lib/main.dart` has been created in the canvas as **Trading Ui Main**. Replace your project's `lib/main.dart` with that file.

---

## Features

* Watchlist with live-updating quotes (polled from Alpha Vantage)
* Mock order placement (BUY / SELL) persisted in app state while running
* Portfolio summary and mock holdings
* Responsive UI with SafeArea and bottom button handling

---

## Prerequisites

* Flutter SDK (stable) installed — tested with Flutter 3.x and above
* An Android device or emulator for `flutter run`
* Alpha Vantage API key (the demo used the key you provided)

---

## Pubspec dependencies

Add the following to your `pubspec.yaml` and run `flutter pub get`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  provider: ^6.0.5
  http: ^0.13.6
```

(Optionally add `web_socket_channel` later if you switch to websockets.)

---

## Files

* `lib/main.dart` — main single-file app created in the canvas (named **Trading Ui Main**)

> Tip: For maintainability you can split `main.dart` into multiple files later (services, models, pages).

---

## How to run

1. Replace `lib/main.dart` in your Flutter project with the `Trading Ui Main` file from the canvas.
2. Ensure the `pubspec.yaml` contains the dependencies above and run:

```bash
flutter pub get
flutter run
```

3. The app will start and poll Alpha Vantage for symbols present in the watchlist.

---

## Alpha Vantage integration

* The demo uses Alpha Vantage `GLOBAL_QUOTE` endpoint to fetch one symbol per interval.
* The polling interval is set to **15 seconds** by default in the `AlphaVantageMarketService` (in `main.dart`). This yields ~4 requests/min — keep this or increase it to avoid hitting free-tier limits.

### Important notes

* **Rate limits**: Free-tier Alpha Vantage is rate-limited (typically 5 requests/min). If you poll too many symbols or set a short interval you may receive a "Note" from the API indicating throttling. The demo handles this gracefully by ignoring those responses.
* **Index symbols**: Alpha Vantage may not accept names like `SENSEX` or `NIFTY` directly. If you need index data, consider using Twelve Data, a broker API, or map the UI names to provider-specific tickers.
* **API key storage**: The demo currently embeds the API key in the code for convenience. For real projects, keep the key out of source control (see *Securing your API key* below).

---

## Securing your API key (recommended)

Options:

1. **Environment define (recommended for CI / local)**

   * Use `--dart-define` when running the app:

     ```bash
     flutter run --dart-define=ALPHA_VANTAGE_KEY=YOUR_KEY_HERE
     ```
   * Read the value in Dart using `const String.fromEnvironment('ALPHA_VANTAGE_KEY')`.

2. **Use `flutter_dotenv`** to load from a `.env` file (remember to add `.env` to `.gitignore`).

3. **Simple local file (not for public repos)**

   * Create `lib/secrets.dart` with `const kAlphaKey = 'YOUR_KEY';` and add `lib/secrets.dart` to `.gitignore`.

---

## Troubleshooting

* **Blank / zero prices**: Alpha Vantage returned no data for the symbol (unsupported or rate-limited). Try a well-known ticker (e.g., `RELIANCE`) or increase the polling interval.
* **"Note" in logs**: You're being rate-limited. Increase the interval or reduce the number of watched symbols.
* **Platform errors**: Run `flutter doctor` and check for missing SDK components.

---

## Next steps / improvements

* Move Alpha Vantage key into secure storage or environment variables.
* Add a symbol lookup/mapping layer (translate UI labels like `SENSEX` → provider-specific tickers).
* Switch to a WebSocket provider for lower-latency streaming (Finnhub, Twelve Data, broker APIs).
* Persist watchlist/orders using `shared_preferences` or Hive.
* Break `main.dart` into modular files and add unit tests.

---

## License

MIT — modify and use freely for testing and development.
