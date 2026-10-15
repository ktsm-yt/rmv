# RMV Float

RMV Float は RMV 専用の macOS アプリです。フローティングウィンドウで `http://127.0.0.1:4310/` を既定で開きます。

実装は RMV Float の `a419b9b` から取り込みました。

## 初めて使うとき

RMV Float は Glaso を参考にした独立ブラウザです。ウィンドウ内に表示する内容が RMV です。

- RMV: AI 作業の進み具合と返事を見る画面
- 起動時: RMV が起動済みなら、既定の RMV を自動で開く
- ホームページ設定: 歯車の **Homepage** から表示先を変えられる。見るだけなら不要
- 最初の操作: 中央の最新返信を読む。別の作業は左上の ≡ から一覧を開いて選ぶ
- RMV 本体: ブラウザとは別。RMV が未起動なら、このブラウザ単体では起動しない
- ホームページ: 起動時と家ボタンで開く URL
- 設定: 歯車の **Homepage** → `http://127.0.0.1:4310/` → **Save**
- 操作: ⌘+ / ⌘− はページの幅に応じて狭い表示へ切り替わり、⌘0 で 100% に戻ります。トラックパッドのピンチは表示のみを拡大縮小します。右 Shift+J から起動、toolbar のピンで常時最前面と通常表示を切り替え、つまみで透明度を調整できます。

## Build and run

```zsh
./scripts/build.sh
open "build/RMV Float.app"
```

The app uses the standard persistent WebKit data store. Use the toolbar for Reload, Home, window opacity, and Homepage settings. Page zoom and trackpad magnification restore after the next launch. Homepage settings accept only HTTP or HTTPS URLs and persist in `UserDefaults` for the next cold launch.

## Test

```zsh
./scripts/test.sh
```

The test covers accepted/rejected URL schemes, persisted homepage retrieval, and link routing. The app deliberately has no tabs, account, payment, or OCR. Clicked web links open in the macOS default app; anchors within the current page stay in RMV Float.

For a running app, confirm that macOS has created a real window without driving its UI:

```zsh
./scripts/assert-window.sh <pid>
```
